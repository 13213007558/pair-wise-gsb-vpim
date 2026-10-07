# -*- encoding : utf-8 -*-
require 'vpim/field'

module Vpim
  # Normalize vCard property identities from copies of one contact.
  #
  # The stable key for a client-assigned PID is the URI in the copy's
  # CLIENTPIDMAP plus the PID's object number. The local client number is not
  # part of that key because devices may renumber it.
  module PropertyIdentity
    class << self

      # Normalize identities in +copies+, an Array of Arrays of
      # Vpim::DirectoryInfo::Field. The result does not choose a winner when
      # properties with the same stable identity have different content.
      def normalize(*arguments)
        options = arguments.last.is_a?(Hash) ? arguments.pop : {}

        if arguments.length == 2
          uid, copies = arguments
          options = { :uid => uid }.merge(options)
        elsif arguments.length == 1
          copies = arguments.first
        else
          raise ArgumentError, 'wrong number of arguments'
        end

        Normalizer.new(options).normalize(to_copy_arrays(copies))
      end

      alias normalize_field_copies normalize
      alias normalize_properties normalize
      alias normalize_pids normalize

      private

      def to_copy_arrays(copies)
        unless copies.respond_to?(:to_ary)
          raise ArgumentError, 'copies must be an array of field arrays'
        end

        array = copies.to_ary
        array = [array] if array.all? { |item| item.kind_of? DirectoryInfo::Field }

        result = []
        array.each_with_index do |copy, copy_index|
          fields = if copy.respond_to?(:fields)
            copy.fields
          elsif copy.respond_to?(:to_ary)
            copy.to_ary
          else
            raise ArgumentError, "copy #{copy_index} must be a field array"
          end

          fields.to_ary.each do |field|
            unless field.kind_of? DirectoryInfo::Field
              raise ArgumentError, "copy #{copy_index} must contain Field objects"
            end
          end
          result << fields
        end
        result
      end
    end

    class Normalizer #:nodoc:
      FRAMEWORK_FIELDS = ['BEGIN', 'END', 'VERSION', 'UID', 'CLIENTPIDMAP'].freeze unless defined?(FRAMEWORK_FIELDS)

      def initialize(options)
        @expected_uid = options[:uid] || options['uid']
        @client_maps = {}
        @ambiguous_client_maps = {}
        @conflicts = []
        @issues = []
      end

      def normalize(copies)
        copy_uids = copies.map { |copy| read_uid(copy) }
        effective_uid = unique_uid(copies, copy_uids)

        unless effective_uid
          return result(nil, copies, [], [], false)
        end

        copies.each_with_index do |copy, copy_index|
          read_client_maps(copy, copy_index)
        end

        candidates = []
        copies.each_with_index do |copy, copy_index|
          copy.each_with_index do |field, field_index|
            next if framework_field?(field)

            candidate = {
              :copy => copy_index,
              :field_index => field_index,
              :field => field,
              :identities => [],
              :pid_refs => []
            }
            resolve_pids(candidate)
            candidates << candidate
          end
        end

        groups = build_groups(candidates)
        detect_content_conflicts(groups)

        result(effective_uid, copies, groups, candidates, true)
      end

      private

      def read_uid(copy)
        values = copy.find_all { |field| field.name?('UID') }.map { |field| field.to_text }
        nonempty = values.find_all { |value| value.strip.length > 0 }
        nonempty.map { |value| value.strip }.uniq
      end

      def unique_uid(copies, copy_uids)
        all_uids = copy_uids.flatten.uniq

        copies.each_with_index do |copy, copy_index|
          uids = copy_uids[copy_index]
          if uids.length == 0
            add_issue('missing-uid', { :copy => copy_index }, :reason => 'contact copy has no UID')
          elsif uids.length > 1
            add_conflict('uid-mismatch', nil, :copy => copy_index, :uids => uids.sort,
              :reason => 'one contact copy contains multiple different UIDs')
          end
        end

        uid_conflict = @conflicts.any? { |conflict| conflict[:type] == 'uid-mismatch' }
        missing_uid = @issues.any? { |issue| issue[:type] == 'missing-uid' }

        if @expected_uid
          expected = @expected_uid.to_s.strip
          unless missing_uid || all_uids == [expected]
            add_conflict('uid-mismatch', nil, :expected => expected, :found => all_uids.sort,
              :reason => 'copies do not all have the expected contact UID')
            return nil
          end
          return expected unless uid_conflict
        end

        if uid_conflict || missing_uid
          return nil
        end

        if all_uids.length > 1
          add_conflict('uid-mismatch', nil, :uids => all_uids.sort,
            :reason => 'copies do not all belong to the same contact UID')
          return nil
        end

        all_uids.first
      end

      def read_client_maps(copy, copy_index)
        copy.each_with_index do |field, field_index|
          next unless field.name?('CLIENTPIDMAP')

          ref = field_ref(copy_index, field_index)
          raw = field.value_raw.to_s
          match = /\A\s*(\d+)\s*;(.+)\z/.match(raw)

          unless match
            add_issue('invalid-client-pidmap', ref, :raw => raw,
              :reason => 'CLIENTPIDMAP must be a client number followed by a semicolon and URI')
            next
          end

          client_number = match[1].to_i
          uri = match[2].strip

          if uri.length == 0
            add_issue('invalid-client-pidmap', ref, :raw => raw,
              :reason => 'CLIENTPIDMAP URI is empty')
            next
          end

          ambiguous = @ambiguous_client_maps[[copy_index, client_number]]
          if ambiguous
            unless ambiguous[:uris].include?(uri)
              ambiguous[:uris] << uri
              ambiguous[:refs] << ref
              add_conflict('client-pidmap-conflict', nil, :copy => copy_index, :client_number => client_number,
                :uris => ambiguous[:uris].sort, :references => ambiguous[:refs],
                :reason => 'the same local client number maps to different URIs')
            end
            next
          end

          existing = @client_maps[[copy_index, client_number]]
          if existing && existing[:uri] != uri
            @client_maps.delete([copy_index, client_number])
            @ambiguous_client_maps[[copy_index, client_number]] = {
              :uris => [existing[:uri], uri].uniq,
              :refs => existing[:refs] + [ref]
            }
            add_conflict('client-pidmap-conflict', nil, :copy => copy_index,
              :uris => [existing[:uri], uri].sort,
              :references => existing[:refs] + [ref],
              :reason => 'the same local client number maps to different URIs')
            next
          end

          @client_maps[[copy_index, client_number]] ||= { :uri => uri, :refs => [] }
          @client_maps[[copy_index, client_number]][:refs] << ref
        end
      end

      def resolve_pids(candidate)
        field = candidate[:field]
        pids = field.pvalues('PID')
        return unless pids

        pids.each_with_index do |raw_pid, pid_index|
          token = raw_pid.to_s.strip
          ref = candidate_field_ref(candidate, pid_index)
          pid_record = { :copy => candidate[:copy], :field_index => candidate[:field_index],
            :pid_index => pid_index, :raw => raw_pid }

          match = /\A(\d+)(?:\.(\d+))?\z/.match(token)
          unless match
            add_issue('invalid-pid', ref, :raw => raw_pid, :reason => 'PID must be client.object or an integer')
            candidate[:pid_refs] << pid_record.merge(:status => 'invalid')
            next
          end

          object_number = match[2]
          unless object_number
            add_issue('missing-client-pid', ref, :raw => raw_pid,
              :reason => 'bare PID has no client number and cannot be matched across devices')
            candidate[:pid_refs] << pid_record.merge(:status => 'missing-client')
            next
          end

          client_number = match[1].to_i
          ambiguous = @ambiguous_client_maps[[candidate[:copy], client_number]]
          mapping = @client_maps[[candidate[:copy], client_number]]
          if ambiguous
            add_issue('ambiguous-client-pidmap', ref, :raw => raw_pid, :client_number => client_number,
              :uris => ambiguous[:uris].sort,
              :reason => 'the PID client number has conflicting CLIENTPIDMAP URIs')
            candidate[:pid_refs] << pid_record.merge(:status => 'ambiguous-map')
            next
          elsif !mapping
            add_issue('missing-client-pidmap', ref, :raw => raw_pid, :client_number => client_number,
              :reason => 'no CLIENTPIDMAP URI was found for the PID client number')
            candidate[:pid_refs] << pid_record.merge(:status => 'missing-map')
            next
          end

          identity = [mapping[:uri], object_number.to_i]
          candidate[:identities] << identity
          candidate[:pid_refs] << pid_record.merge(:status => 'resolved', :client_number => client_number,
            :uri => mapping[:uri], :identity => identity)
        end
      end

      def build_groups(candidates)
        parent = candidates.length.times.to_a

        find_root = lambda do |node|
          parent[node] = find_root.call(parent[node]) unless parent[node] == node
          parent[node]
        end

        union = lambda do |left, right|
          left_root = find_root.call(left)
          right_root = find_root.call(right)
          parent[right_root] = left_root unless left_root == right_root
        end

        seen_identity = {}
        candidates.each_with_index do |candidate, index|
          candidate[:identities].each do |identity|
            if previous = seen_identity[identity]
              union.call(previous, index)
            else
              seen_identity[identity] = index
            end
          end
        end

        components = {}
        candidates.each_with_index do |candidate, index|
          root = find_root.call(index)
          components[root] ||= []
          components[root] << candidate
        end

        groups = components.values.collect do |members|
          identities = members.inject([]) { |all, member| all + member[:identities] }.uniq.sort
          resolved = identities.length > 0
          {
            :resolved => resolved,
            :identities => identities.map { |uri, object| { :uri => uri, :object => object } },
            :properties => members.collect { |member| member[:field] },
            :property_refs => members.collect { |member| field_ref(member[:copy], member[:field_index]) },
            :candidates => members.collect { |member| field_ref(member[:copy], member[:field_index]) },
            :pid_refs => members.inject([]) { |all, member| all + member[:pid_refs] }
          }
        end

        assign_group_ids(groups)
      end

      def assign_group_ids(groups)
        identified = groups.find_all { |group| group[:resolved] }
        independent = groups.find_all { |group| !group[:resolved] }

        identified.sort_by! do |group|
          group[:identities].collect { |identity| [identity[:uri], identity[:object]] }
        end
        independent.sort_by! { |group| ref = group[:property_refs].first; [ref[:copy], ref[:field_index]] }

        ordered = identified + independent
        ordered.each_with_index do |group, index|
          group[:number] = index + 1
          group[:id] = group[:number]
        end
        ordered
      end

      def detect_content_conflicts(groups)
        groups.each do |group|
          next unless group[:resolved]

          variants = []
          group[:properties].each_with_index do |field, index|
            signature = property_signature(field)
            variant = variants.detect { |item| item[:signature] == signature }
            if variant
              variant[:references] << group[:property_refs][index]
            else
              variants << { :signature => signature, :references => [group[:property_refs][index]] }
            end
          end

          if variants.length > 1
            group[:conflict] = true
            conflict = add_conflict('property-content-conflict', group[:number],
              :references => variants.inject([]) { |all, variant| all + variant[:references] },
              :variants => variants.length,
              :reason => 'properties with the same stable identity have different content')
            group[:conflicts] = [conflict]
          else
            group[:conflict] = false
            group[:conflicts] = []
          end
        end
      end

      def property_signature(field)
        params = {}
        field.each_param do |name, values|
          next if name == 'PID'
          params[name] = values.dup
        end
        [field.group, field.name, field.value_raw, params.sort]
      end

      def signature_difference(left, right)
        left_group, left_name, left_value, left_params = left
        right_group, right_name, right_value, right_params = right
        differences = []
        differences << 'group' unless left_group == right_group
        differences << 'name' unless Vpim::Methods.casecmp?(left_name, right_name)
        differences << 'value' unless left_value == right_value
        differences << 'parameters' unless left_params == right_params
        differences
      end

      def result(uid, copies, groups, candidates = [], valid = false)
        ordered_client_uris = @client_maps.values.map { |mapping| mapping[:uri] }.uniq.sort
        client_numbers = {}
        ordered_client_uris.each_with_index do |uri, index|
          client_numbers[uri] = index + 1
        end

        client_map_entries = @client_maps.collect do |(copy, local), mapping|
          { :copy => copy, :local_client => local, :client => client_numbers[mapping[:uri]],
            :uri => mapping[:uri], :field_refs => mapping[:refs], :resolved => true }
        end

        @ambiguous_client_maps.each do |(copy, local), mapping|
          client_map_entries << { :copy => copy, :local_client => local, :client => nil,
            :uri => nil, :uris => mapping[:uris].sort, :field_refs => mapping[:refs],
            :resolved => false }
        end

        client_map_entries.sort_by { |entry| [entry[:copy], entry[:local_client]] }

        pid_map = groups.collect do |group|
          { :group => group[:number], :property_refs => group[:property_refs],
            :resolved => group[:resolved], :identities => group[:identities] }
        end

        pid_refs = candidates.inject([]) { |all, candidate| all + candidate[:pid_refs] }
        pid_entries = pid_refs.collect do |pid_ref|
          entry = {
            :copy => pid_ref[:copy],
            :field_index => pid_ref[:field_index],
            :pid_index => pid_ref[:pid_index],
            :raw => pid_ref[:raw],
            :status => pid_ref[:status]
          }
          if pid_ref[:status] == 'resolved'
            entry[:local_client] = pid_ref[:client_number]
            entry[:client] = client_numbers[pid_ref[:uri]]
            entry[:uri] = pid_ref[:uri]
            entry[:object] = pid_ref[:identity][1]
            group = groups.detect do |item|
              item[:resolved] && item[:property_refs].include?(
                :copy => pid_ref[:copy], :field_index => pid_ref[:field_index])
            end
            entry[:group] = group[:number] if group
          end
          entry
        end

        result = {
          :uid => uid,
          :ok => valid,
          :valid => valid,
          :client_maps => client_map_entries,
          :client_pidmaps => client_map_entries,
          :pid_map => pid_map,
          :number_map => pid_map,
          :pids => pid_entries,
          :groups => groups,
          :property_groups => groups,
          :conflicts => @conflicts,
          :issues => @issues,
          :errors => @issues,
          :copies => copies.length
        }
        result
      end

      def framework_field?(field)
        FRAMEWORK_FIELDS.any? { |name| field.name?(name) }
      end

      def field_ref(copy_index, field_index)
        { :copy => copy_index, :field_index => field_index }
      end

      def candidate_field_ref(candidate, pid_index)
        field_ref(candidate[:copy], candidate[:field_index]).merge(:pid_index => pid_index)
      end

      def add_conflict(type, group, details)
        conflict = { :type => type, :group => group }.merge(details)
        @conflicts << conflict
        conflict
      end

      def add_issue(type, ref, details)
        @issues << { :type => type, :ref => ref }.merge(details)
      end
    end
  end

  def Vpim.normalize_property_identities(*arguments)
    PropertyIdentity.normalize(*arguments)
  end

  class << Vpim
    alias normalize_field_identities normalize_property_identities
    alias normalize_pids normalize_property_identities
  end
end
