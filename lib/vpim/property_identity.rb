=begin
  This library is free software; you can redistribute it and/or modify it
  under the same terms as the ruby language itself, see the file COPYING for
  details.
=end

require 'vpim/field'

module Vpim
  # Property identity normalization across multiple copies of the same
  # contact (the same UID), as needed by CardDAV-style synchronization.
  #
  # Different devices assign different local PIDs to the same property, and
  # each device numbers its CLIENTPIDMAP entries independently, so neither
  # the literal PID string nor the property text can be used to decide
  # whether two properties are "the same". A stable identity is established
  # by combining the client part of a PID with the URI that the copy's
  # CLIENTPIDMAP associates with the PID's source part (RFC 6350):
  #
  #   TEL;PID=4.2:+1-555-0100        +  CLIENTPIDMAP:2;urn:uuid:device-b
  #
  # gives the identity (urn:uuid:device-b, 4), which means the same thing in
  # every copy no matter how each device numbered its CLIENTPIDMAP entries.
  #
  # A property may carry several PIDs; identities that overlap on any
  # property are merged into a single group.
  #
  # The input is the low-level Vpim::DirectoryInfo::Field objects of each
  # copy, no complete vCard 4 decoding is required. The output is a
  # normalized numbering of the identities, the property groups, and any
  # conflicts detected. Which content should win inside a conflicting group
  # is deliberately NOT decided here.
  #
  # Example:
  #
  #   result = Vpim::PropertyIdentity.normalize([fields_from_a, fields_from_b])
  #   result.mapping   # { Identity => canonical number }
  #   result.groups    # all property groups (identified and candidates)
  #   result.conflicts # groups whose members disagree, or duplicate identities
  #   result.issues    # explained anomalies (missing mappings, bad UIDs, ...)
  module PropertyIdentity
    # Names that describe the card or the PID mapping itself. They are used
    # for consistency checks, but never take part in property grouping.
    STRUCTURAL_NAMES = %w[BEGIN END VERSION CLIENTPIDMAP UID].freeze

    # A stable, device-independent property identity: the client part of a
    # PID together with the CLIENTPIDMAP URI of the client that assigned it.
    class Identity
      include Comparable

      attr_reader :client_uri, :client_pid

      def initialize(client_uri, client_pid)
        @client_uri = client_uri.to_str.freeze
        @client_pid = Integer(client_pid)
        freeze
      end

      def <=>(other)
        [ client_uri, client_pid ] <=> [ other.client_uri, other.client_pid ]
      end

      def ==(other)
        other.kind_of?(Identity) &&
          client_uri == other.client_uri && client_pid == other.client_pid
      end

      alias eql? ==

      def hash
        [ client_uri, client_pid ].hash
      end

      def to_s
        "#{client_pid}@#{client_uri}"
      end

      alias inspect to_s
    end

    # A property occurrence: the Field as found in one of the copies.
    Member = Struct.new(:copy_index, :field)

    # An anomaly that prevented normal normalization, with an explanation.
    # +reason+ is one of :missing_uid, :inconsistent_uid,
    # :invalid_clientpidmap, :invalid_pid, :pid_without_source, or
    # :missing_clientpidmap_entry. +field+ is nil for copy-level issues.
    Issue = Struct.new(:copy_index, :field, :reason, :message)

    # A group of properties that share at least one identity. Groups with
    # no identities are independent candidates: properties without a usable
    # PID, kept separate from each other even if their text is identical.
    class Group
      attr_reader :identities, :members

      # The canonical number of this group (the lowest number its identities
      # received in Result#mapping), or nil for independent candidates.
      attr_accessor :number

      def initialize(identities, members) #:nodoc:
        @identities = identities
        @members = members
        @number = nil
      end

      # Whether this group has a stable identity. False for independent
      # candidates (properties without a usable PID).
      def identified?
        !@identities.empty?
      end

      # The indexes of the copies the members come from, in encounter order.
      def copy_indexes
        @members.map { |m| m.copy_index }.uniq
      end

      # The distinct [name, value] pairs of the members.
      def contents
        @members.map { |m| [ m.field.name, m.field.value ] }.uniq
      end
    end

    # A disagreement inside a group. +kind+ is :value_mismatch when members
    # sharing an identity carry different content, or :duplicate_in_copy when
    # a single copy assigns the same identity to several properties. The
    # conflicting members stay in the group; resolution is up to the caller.
    Conflict = Struct.new(:group, :kind, :message)

    # The outcome of PropertyIdentity.normalize.
    class Result
      # The UID shared by the copies (the first one seen), or nil.
      attr_reader :uid

      # Hash of Identity => canonical number (1-based, assigned in sorted
      # identity order). Devices can renumber their local PIDs to these.
      attr_reader :mapping

      # All groups: identified groups first (ordered by canonical number),
      # then independent candidates in encounter order.
      attr_reader :groups

      # Array of Conflict.
      attr_reader :conflicts

      # Array of Issue.
      attr_reader :issues

      def initialize(uid, mapping, groups, conflicts, issues) #:nodoc:
        @uid = uid
        @mapping = mapping
        @groups = groups
        @conflicts = conflicts
        @issues = issues
      end

      # The groups that have a stable identity.
      def identified_groups
        @groups.select { |g| g.identified? }
      end

      # The independent candidates: properties without a usable PID, each in
      # its own singleton group.
      def candidates
        @groups.reject { |g| g.identified? }
      end
    end

    # Normalize the property identities of +copies+, an Array of per-device
    # copies of the same contact. Each copy is an Array of
    # Vpim::DirectoryInfo::Field (or anything Enumerable of Field, such as a
    # Vpim::DirectoryInfo). Returns a Result.
    def self.normalize(copies)
      copies = copies.map { |c| c.to_a }
      issues = []
      uid = nil
      pidmaps = []

      copies.each_with_index do |fields, i|
        uids = fields.select { |f| f.name == 'UID' }.
          map { |f| f.value.to_s.strip }.reject { |u| u.empty? }.uniq

        if uids.empty?
          issues << Issue.new(i, nil, :missing_uid,
            "copy #{i} has no UID field, it cannot be confirmed as a copy of the same contact")
        else
          if uids.size > 1
            issues << Issue.new(i, nil, :inconsistent_uid,
              "copy #{i} carries several different UIDs #{uids.inspect}")
          end
          if uid.nil?
            uid = uids.first
          elsif uids.first != uid
            issues << Issue.new(i, nil, :inconsistent_uid,
              "copy #{i} has UID #{uids.first.inspect}, but the contact is identified by #{uid.inspect} in the other copies")
          end
        end

        pidmap = {}
        fields.select { |f| f.name == 'CLIENTPIDMAP' }.each do |f|
          source, uri = f.value.to_s.split(';', 2)
          if source =~ /\A\d+\z/ && uri && !uri.empty?
            pidmap[source.to_i] = uri
          else
            issues << Issue.new(i, f, :invalid_clientpidmap,
              "CLIENTPIDMAP #{f.value.inspect} in copy #{i} is not of the form <source>;<uri>")
          end
        end
        pidmaps << pidmap
      end

      # Union-find over identities; identities co-occurring on one property
      # belong to the same group.
      parent = {}
      find = lambda do |x|
        root = x
        root = parent[root] while parent.key?(root)
        while parent.key?(x)
          parent[x], x = root, parent[x]
        end
        root
      end
      union = lambda do |a, b|
        ra, rb = find.call(a), find.call(b)
        parent[rb] = ra unless ra.eql?(rb)
      end

      entries = [] # [ [Identity, ...], Member ]

      copies.each_with_index do |fields, i|
        fields.each do |f|
          next if STRUCTURAL_NAMES.include?(f.name)

          identities = []
          (f.pvalues('PID') || []).each do |pid|
            text = pid.to_s.strip
            match = /\A(\d+)(?:\.(\d+))?\z/.match(text)
            if match.nil?
              issues << Issue.new(i, f, :invalid_pid,
                "PID #{text.inspect} on #{f.name} in copy #{i} is not of the form <client>[.<source>]")
            elsif match[2].nil?
              issues << Issue.new(i, f, :pid_without_source,
                "PID #{text.inspect} on #{f.name} in copy #{i} has no source part, so its assigning client cannot be resolved through CLIENTPIDMAP")
            else
              uri = pidmaps[i][match[2].to_i]
              if uri.nil?
                issues << Issue.new(i, f, :missing_clientpidmap_entry,
                  "PID #{text.inspect} on #{f.name} refers to source #{match[2]}, but copy #{i} has no CLIENTPIDMAP entry for that source")
              else
                identities << Identity.new(uri, match[1].to_i)
              end
            end
          end
          identities.uniq!
          identities.each_cons(2) { |a, b| union.call(a, b) }

          entries << [ identities, Member.new(i, f) ]
        end
      end

      groups_by_root = {}
      groups = []

      entries.each do |identities, member|
        if identities.empty?
          groups << Group.new([], [ member ])
        else
          root = find.call(identities.first)
          group = groups_by_root[root]
          unless group
            group = Group.new([], [])
            groups_by_root[root] = group
            groups << group
          end
          group.identities.concat(identities)
          group.members << member
        end
      end

      groups.each { |g| g.identities.uniq! }

      mapping = {}
      groups.flat_map { |g| g.identities }.uniq.sort.each_with_index do |id, n|
        mapping[id] = n + 1
      end

      groups.each do |g|
        g.number = g.identities.map { |id| mapping[id] }.min if g.identified?
      end

      identified, candidates = groups.partition { |g| g.identified? }
      groups = identified.sort_by { |g| g.number } + candidates

      conflicts = []
      groups.each do |g|
        counts = Hash.new(0)
        g.members.each { |m| counts[m.copy_index] += 1 }
        duplicates = counts.select { |_, c| c > 1 }.keys
        unless duplicates.empty?
          conflicts << Conflict.new(g, :duplicate_in_copy,
            "copies #{duplicates.inspect} assign the same identity (#{g.identities.join(', ')}) to more than one property")
        end

        contents = g.contents
        if contents.size > 1
          conflicts << Conflict.new(g, :value_mismatch,
            "properties sharing identity (#{g.identities.join(', ')}) have different content #{contents.inspect}; no content is overridden here")
        end
      end

      Result.new(uid, mapping, groups, conflicts, issues)
    end
  end
end

