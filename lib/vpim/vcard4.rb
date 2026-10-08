# -*- encoding : utf-8 -*-
=begin
  vCard 4.0 (RFC 6350) support.

  This file adds explicit vCard 4.0 reading and generation to the vCard 3.0
  implementation in vpim/vcard.rb. The key difference from 2.1/3.0 is that
  the value of a property is typed (TEXT, URI, DATE-AND-OR-TIME, ...) and
  that information must be preserved rather than forcing the value into the
  2.1/3.0 assumptions:

  - BDAY/ANNIVERSARY may be a reduced-precision date with no year
    ("--0229"), a year of zero ("00000229"), or a date-time; absence of a
    year or a time zone is meaningful and is never filled in.
  - TEL defaults to a URI, and may be a "tel:" URI (with extensions, etc.).
  - GEO defaults to a "geo:" URI.
  - TZ may be TEXT, a URI, or a UTC-OFFSET.
  - N and ADR are structured TEXT whose components may themselves be lists.
=end

require 'vpim/vcard'
require 'date'

module Vpim
  module Vcard4
    # Regexps implementing the RFC 6350 4.3 grammar (subset needed for
    # DATE-AND-OR-TIME and UTC-OFFSET).
    module Grammar #:nodoc:
      YEAR      = '(\d{4})'
      MONTH     = '(\d{2})'
      DAY       = '(\d{2})'
      HOUR      = '(\d{2})'
      MINUTE    = '(\d{2})'
      SECOND    = '(\d{2})'
      SIGN      = '([+-])'

      # utc-offset (4.3.3): sign hour [":" minute [":" second]].
      # The compact v3 legacy form ("-0500") is accepted on input, too.
      OFFSET = "#{SIGN}#{HOUR}(?::#{MINUTE}(?::#{SECOND})?|#{MINUTE}(?:#{SECOND})?)?"
    end

    # A DATE-AND-OR-TIME value (RFC 6350 4.3.4), or a UTC-OFFSET value for
    # TZ. Every part is optional except those present; the encoded form is
    # retained so that omitted information (a missing year, a missing time
    # zone) round-trips exactly instead of being replaced by defaults.
    #
    # Attributes (nil when absent from the value):
    # - year (Integer or nil): 0 is a real "year zero", distinct from nil.
    # - month, day (Integer or nil)
    # - hour, minute, second (Integer or nil)
    # - secfrac (String or nil): the fractional-second text, e.g. ".5"
    # - zone (String or nil): "Z" or "+HH:MM"; nil means a floating time,
    #   it is never expanded to the local zone.
    # - offset (String or nil): for UTC-OFFSET values, the whole offset.
    class DateAndOrTime
      attr_accessor :year, :month, :day, :hour, :minute, :second, :secfrac, :zone
      attr_reader :original

      def initialize(year: nil, month: nil, day: nil, hour: nil, minute: nil,
                     second: nil, secfrac: nil, zone: nil, original: nil)
        @year = year
        @month = month
        @day = day
        @hour = hour
        @minute = minute
        @second = second
        @secfrac = secfrac
        @zone = zone
        @original = original
        validate!
      end

      def year?; !@year.nil?; end
      def date?; @year && @month && @day && @hour.nil?; end
      def time?; !@hour.nil?; end
      def floating?; time? && @zone.nil?; end

      # Convert to a Date, only when year, month and day are all present.
      def to_date
        unless @year && @month && @day
          raise ArgumentError, "#{to_s} has no complete date"
        end
        Date.new(@year, @month, @day)
      end

      # Convert to a DateTime, only when the value is a full date-time.
      # A floating value (no zone) yields a DateTime with offset 0 only for
      # comparison purposes; the zone information of the value itself is
      # left untouched and #to_s preserves it.
      def to_datetime
        unless @year && @month && @day && @hour && @minute && @second
          raise ArgumentError, "#{to_s} is not a complete date-time"
        end
        DateTime.new(@year, @month, @day, @hour, @minute, @second, zone_offset)
      end

      def to_str
        @original || encode
      end
      alias to_s to_str

      def ==(other)
        other.is_a?(DateAndOrTime) && to_s == other.to_s
      end
      alias eql? ==
      def hash; to_s.hash; end
      def inspect; "#<#{self.class} #{to_s.inspect}>"; end

      def encode
        d =
          if @year && @month && @day
            format('%04d-%02d-%02d', @year, @month, @day)
          elsif @year && @month
            format('%04d-%02d', @year, @month)
          elsif @year
            format('%04d', @year)
          elsif @month && @day
            format('--%02d-%02d', @month, @day)
          elsif @month
            format('--%02d', @month)
          else
            ''
          end

        if @hour
          t = if @minute && @second
                format('%02d:%02d:%02d', @hour, @minute, @second)
              elsif @minute
                format('%02d:%02d', @hour, @minute)
              else
                format('%02d', @hour)
              end
          t << @secfrac.to_s
          t << @zone.to_s
          d = d.empty? ? t : d + 'T' + t
        end
        d
      end

      def validate!
        if @year && (!@year.between?(0, 9999))
          raise Vpim::InvalidEncodingError, "year #{@year} out of range"
        end
        if @month && !@month.between?(1, 12)
          raise Vpim::InvalidEncodingError, "month #{@month} out of range"
        end
        if @day && @month
          y = @year || 2000
          days = @month == 2 ? (leap?(y) ? 29 : 28) : [nil,31,nil,31,30,31,30,31,31,30,31,30,31][@month]
          unless @day.between?(1, days)
            raise Vpim::InvalidEncodingError, "day #{@day} not valid for month #{@month}"
          end
        elsif @day && !@day.between?(1, 31)
          raise Vpim::InvalidEncodingError, "day #{@day} out of range"
        end
        [[:hour, 23], [:minute, 59], [:second, 60]].each do |attr, max|
          val = send(attr)
          if val && !val.between?(0, max)
            raise Vpim::InvalidEncodingError, "#{attr} #{val} out of range"
          end
        end
      end

      private

      def zone_offset
        case @zone
        when nil, 'Z' then 0
        when /\A([+-])(\d\d):(\d\d)\z/
          min = $2.to_i * 60 + $3.to_i
          # Rational offset for DateTime
          Rational(($1 == '-' ? -min : min), 1440)
        else 0
        end
      end

      def leap?(year)
        (year % 4 == 0 && year % 100 != 0) || (year % 400 == 0)
      end

      public

      # Parse a RFC 6350 4.3.4 date-and-or-time. Raises
      # Vpim::InvalidEncodingError on malformed values.
      def self.decode(value)
        v = value.to_s.strip
        m = parse_full(v) || parse_partial(v) || parse_time(v) || parse_year(v)
        unless m
          raise Vpim::InvalidEncodingError, "date-and-or-time not valid (#{value})"
        end
        m
      end

      def self.parse_full(v) #:nodoc:
        datepart = '(?<year>\d{4})(?:-(?<month>\d{2})-(?<day>\d{2})|(?<monthc>\d{2})(?<dayc>\d{2}))'
        ext_t = 'T(?<hour>\d{2})(?::(?<minute>\d{2})(?::(?<second>\d{2})(?<secfrac>\.\d+)?)?)?(?<zone>Z|[+-]\d{2}:\d{2})?'
        cmp_t = 'T(?<hourc>\d{2})(?:(?<minutec>\d{2})(?:(?<secondc>\d{2})(?<secfracc>\.\d+)?)?)?(?<zonec>Z|[+-]\d{2}\d{2})?'
        re = %r{\A#{datepart}(?:#{ext_t}|#{cmp_t})?\z}
        md = re.match(v)
        return nil unless md
        month = md[:month] || md[:monthc]
        day   = md[:day]   || md[:dayc]
        hour   = md[:hour]   || md[:hourc]
        minute = md[:minute] || md[:minutec]
        second = md[:second] || md[:secondc]
        secfrac = md[:secfrac] || md[:secfracc]
        zone = (md[:zone] || md[:zonec])
        zone = zone && zone.sub(/([+-]\d{2})(\d{2})\z/, '\1:\2')
        new(year: md[:year].to_i, month: month.to_i, day: day.to_i,
            hour: hour && hour.to_i, minute: minute && minute.to_i,
            second: second && second.to_i, secfrac: secfrac,
            zone: zone, original: v)
      end

      def self.parse_partial(v) #:nodoc:
        case v
        when %r{\A--(?:#{Grammar::MONTH}-#{Grammar::DAY}|(\d\d)(\d\d))\z}
          m = $1 || $3
          d = $2 || $4
          new(month: m.to_i, day: d.to_i, original: v)
        when %r{\A--#{Grammar::MONTH}\z}
          new(month: $1.to_i, original: v)
        else nil
        end
      end

      def self.parse_year(v) #:nodoc:
        case v
        when %r{\A#{Grammar::YEAR}-#{Grammar::MONTH}\z}
          new(year: $1.to_i, month: $2.to_i, original: v)
        when %r{\A#{Grammar::YEAR}\z}
          new(year: v.to_i, original: v)
        else nil
        end
      end

      def self.parse_time(v) #:nodoc:
        re = %r{\A(?<hour>\d{2})(?::(?<minute>\d{2})(?::(?<second>\d{2})(?<secfrac>\.\d+)?)?)?(?<zone>Z|[+-]\d{2}:\d{2})?\z}
        md = re.match(v)
        return nil unless md
        new(hour: md[:hour].to_i, minute: md[:minute] && md[:minute].to_i,
            second: md[:second] && md[:second].to_i, secfrac: md[:secfrac],
            zone: md[:zone], original: v)
      end
    end

    # A UTC-OFFSET value for TZ (RFC 6350 4.3.3), e.g. "+02:00" or the
    # legacy v3 form "--05:00" accepted on input.
    class UtcOffset
      def self.decode(value)
        v = value.to_s.strip.sub(/\A--/, '')
        unless v =~ %r{\A#{Grammar::OFFSET}\z}
          raise Vpim::InvalidEncodingError, "utc-offset not valid (#{value})"
        end
        new(value.to_s.strip)
      end

      def initialize(original)
        @original = original
      end

      attr_reader :original

      def to_str
        @original
      end
      alias to_s to_str
      def inspect; "#<#{self.class} #{@original.inspect}>"; end
      def ==(other); other.is_a?(UtcOffset) && to_s == other.to_s; end
      alias eql? ==
      def hash; to_s.hash; end
    end

    # Minimal, non-network URI syntax validation (RFC 3986). Only the
    # syntax is checked; the URI is never opened.
    module UriValue
      SCHEME      = '[A-Za-z][A-Za-z0-9+.-]*'
      URIC        = '[^\x00-\x20]'
      HIERARCHY   = "(?:\/\/#{URIC}*)?"
      GENERIC_URI = "#{SCHEME}:#{HIERARCHY}#{URIC}*"

      def UriValue.valid?(value)
        value.to_s =~ %r{\A#{GENERIC_URI}\z} ? true : false
      end

      def UriValue.validate!(property, value)
        unless valid?(value)
          raise Vpim::InvalidEncodingError,
            "#{property};VALUE=URI has an invalid URI (#{value})"
        end
      end
    end

    # A decoded GEO value for vCard 4.0: either a geo: URI (default) or a
    # legacy structured pair with VALUE=text.
    class Geo
      # 'uri' or 'text'
      attr_reader :value_type
      # Attachment::Uri when #value_type is 'uri'
      attr_reader :uri
      # [lat, lon] Floats when #value_type is 'text', or parsed from a geo:
      # URI when it is 'uri'
      attr_reader :coordinates

      def initialize(value_type, value)
        @value_type = value_type
        case value_type
        when 'uri'
          UriValue.validate!('GEO', value)
          @uri = Vpim::Attachment::Uri.new(value, nil)
          @coordinates = parse_geo_uri(value)
        when 'text'
          @coordinates = Vpim.decode_list(value, ';') { |item| item.strip.to_f }
          unless @coordinates.size == 2 && @coordinates.all? { |c| c.is_a?(Numeric) }
            raise Vpim::InvalidEncodingError, "GEO text must be 'latitude;longitude' (#{value})"
          end
        else
          raise Vpim::InvalidEncodingError, "GEO VALUE=#{value_type.upcase} is not allowed"
        end
      end

      def latitude; @coordinates && @coordinates[0]; end
      def longitude; @coordinates && @coordinates[1]; end
      def to_s; value_type == 'uri' ? @uri.uri : @coordinates.join(';'); end

      private

      def parse_geo_uri(value)
        md = %r{\Ageo:\s*(-?\d+(?:\.\d+)?),\s*(-?\d+(?:\.\d+)?)}i.match(value.to_s)
        unless md
          raise Vpim::InvalidEncodingError, "GEO uri is not a geo URI (#{value})"
        end
        [md[1].to_f, md[2].to_f]
      end
    end

    # Registration of the value types allowed for a property, by version.
    #
    # Each entry is a Registration with:
    # - name: property name (upcased)
    # - defaults: Hash of profile (21/30/40) to default VALUE token
    # - allowed: Hash of profile to Array of allowed VALUE tokens
    # - decoder: proc(field, card) used when decoding (optional)
    PropertyRegistration = Struct.new(:name, :defaults, :allowed, :decoder)

    class PropertyRegistration
      def versions_allowed?(profile)
        allowed.key?(profile)
      end

      def allowed?(profile, kind)
        list = allowed[profile]
        list && list.include?(kind.to_s.downcase)
      end

      def default(profile)
        defaults[profile]
      end
    end

    @registry = {}

    class << self
      attr_reader :registry

      # Register (or replace) the value types for +property+. +defaults+
      # maps a profile (21, 30, 40) to the default VALUE when no VALUE
      # parameter is present; +allowed+ maps a profile to the allowed VALUE
      # tokens. Extension properties can use this to declare their own type,
      # for example:
      #
      #   Vpim::Vcard4.register_property('X-SPONSOR',
      #     40 => { 'default' => 'uri', 'allowed' => ['text', 'uri'] })
      def register_property(name, versions, &decoder)
        defaults = {}
        allowed = {}
        versions.each do |profile, spec|
          spec = { 'default' => spec, 'allowed' => [spec] } if spec.is_a?(String)
          defaults[profile] = spec['default']
          allowed[profile] = spec['allowed']
        end
        @registry[name.to_s.upcase] =
          PropertyRegistration.new(name.to_s.upcase, defaults, allowed, decoder)
      end

      def registered(name)
        @registry[name.to_s.upcase]
      end

      def registered_kind(name, kind)
        reg = registered(name)
        reg && kind && reg.allowed.values.flatten.include?(kind.to_s.downcase) ? reg : nil
      end
    end

    register_property('N',
      21 => { 'default' => 'text', 'allowed' => ['text'] },
      30 => { 'default' => 'text', 'allowed' => ['text'] },
      40 => { 'default' => 'text', 'allowed' => ['text'] })

    register_property('ADR',
      21 => { 'default' => 'text', 'allowed' => ['text'] },
      30 => { 'default' => 'text', 'allowed' => ['text'] },
      40 => { 'default' => 'text', 'allowed' => ['text'] })

    register_property('BDAY',
      30 => { 'default' => 'date', 'allowed' => ['date', 'date-time'] },
      40 => { 'default' => 'date-and-or-time',
              'allowed' => ['date-and-or-time', 'text'] })

    register_property('ANNIVERSARY',
      40 => { 'default' => 'date-and-or-time',
              'allowed' => ['date-and-or-time', 'text'] })

    register_property('TEL',
      21 => { 'default' => 'text', 'allowed' => ['text'] },
      30 => { 'default' => 'text', 'allowed' => ['text'] },
      40 => { 'default' => 'uri', 'allowed' => ['uri', 'text'] })

    register_property('GEO',
      21 => { 'default' => 'text', 'allowed' => ['text'] },
      30 => { 'default' => 'text', 'allowed' => ['text'] },
      40 => { 'default' => 'uri', 'allowed' => ['uri', 'text'] })

    register_property('TZ',
      21 => { 'default' => 'text', 'allowed' => ['text'] },
      30 => { 'default' => 'text', 'allowed' => ['text'] },
      40 => { 'default' => 'text',
              'allowed' => ['text', 'uri', 'utc-offset', 'date-and-or-time'] })

    # Decoders used to override the 2.1/3.0 Vcard#@@decode table for a
    # VERSION:4.0 card.
    DECODE_V4 = {
      'BDAY'        => :decode_v4_bday,
      'ANNIVERSARY' => :decode_v4_anniversary,
      'TEL'         => :decode_v4_tel,
      'GEO'         => :decode_v4_geo,
      'TZ'          => :decode_v4_tz,
    }

    # Validate all VALUE parameters in a vCard 4.0 card. Raises
    # InvalidEncodingError with a clear message for a bad combination.
    def self.validate_card!(card)
      card.each do |f|
        name = f.name
        reg = registry[name]
        next unless reg

        kind = f.kind || reg.default(40)

        unless reg.allowed?(40, kind)
          raise Vpim::InvalidEncodingError,
            "#{name};VALUE=#{kind.upcase} is not valid for vCard 4.0 (allowed: #{reg.allowed[40].join(', ')})"
        end

        # Eagerly parse the typed value so malformed input fails at decode.
        case [name, kind]
        when ['BDAY', 'date-and-or-time'], ['ANNIVERSARY', 'date-and-or-time']
          DateAndOrTime.decode(f.value_raw)
        when ['GEO', 'uri']
          UriValue.validate!(name, f.value_raw)
        when ['GEO', 'text']
          # structural check happens lazily; only verify a semicolon pair
          unless f.value_raw =~ %r{\A[^;]*;[^;]*\z}
            raise Vpim::InvalidEncodingError, "GEO text must be 'latitude;longitude'"
          end
        when ['TZ', 'uri']
          UriValue.validate!(name, f.value_raw)
        when ['TZ', 'utc-offset']
          UtcOffset.decode(f.value_raw)
        when ['TZ', 'date-and-or-time']
          DateAndOrTime.decode(f.value_raw)
        when ['TEL', 'uri']
          UriValue.validate!(name, f.value_raw)
        end
      end
    end

    # Called by the maker once a VERSION:4.0 card is complete.
    def self.validate_maker!(card)
      validate_card!(card)
    end

    module Decoders #:nodoc:all
      def decode_v4_registered(field)
        reg = Vpim::Vcard4.registered(field.name)
        kind = field.kind || (reg && reg.default(40)) || 'text'
        value =
          if reg && reg.decoder
            reg.decoder.call(field, self)
          elsif kind == 'uri'
            Vpim::Vcard4::UriValue.validate!(field.name, field.value_raw)
            Vpim::Attachment::Uri.new(field.value_raw, nil)
          else
            Vpim.decode_text(field.value_raw)
          end
        Vpim::Vcard::Line.new(field.group, field.name, value)
      end

      def decode_v4_bday(field)
        decode_v4_datetime(field, 'BDAY')
      end

      def decode_v4_anniversary(field)
        decode_v4_datetime(field, 'ANNIVERSARY')
      end

      def decode_v4_datetime(field, name)
        kind = field.kind || 'date-and-or-time'
        value =
          case kind
          when 'date-and-or-time'
            DateAndOrTime.decode(field.value_raw)
          when 'text'
            Vpim.decode_text(field.value_raw)
          else
            raise Vpim::InvalidEncodingError,
              "#{name};VALUE=#{kind.upcase} is not valid for vCard 4.0"
          end
        Vpim::Vcard::Line.new(field.group, field.name, value)
      end

      def decode_v4_tel(field)
        Vpim::Vcard::Line.new(field.group, field.name,
                             Vpim::Vcard::Telephone.decode(field, 40))
      end

      def decode_v4_geo(field)
        kind = field.kind || 'uri'
        Vpim::Vcard::Line.new(field.group, field.name, Geo.new(kind, field.value_raw))
      end

      def decode_v4_tz(field)
        kind = field.kind || 'text'
        value =
          case kind
          when 'text'
            Vpim.decode_text(field.value_raw)
          when 'uri'
            UriValue.validate!('TZ', field.value_raw)
            Vpim::Attachment::Uri.new(field.value_raw, nil)
          when 'utc-offset'
            UtcOffset.decode(field.value_raw)
          when 'date-and-or-time'
            DateAndOrTime.decode(field.value_raw)
          else
            raise Vpim::InvalidEncodingError,
              "TZ;VALUE=#{kind.upcase} is not valid for vCard 4.0"
          end
        Vpim::Vcard::Line.new(field.group, field.name, value)
      end
    end

    Vpim::Vcard.send(:include, Decoders)

    # Encode a BDAY/ANNIVERSARY value for the given profile.
    def self.encode_datetime_field(name, value, profile)
      case value
      when DateAndOrTime
        if profile == 40
          params = value.is_a?(UtcOffset) ? { 'VALUE' => 'UTC-OFFSET' } : {}
          Vpim::DirectoryInfo::Field.create(name, value.to_s, params)
        else
          raise Vpim::Unencodeable,
            "#{name} reduced-precision/offset values cannot be encoded in vCard #{profile / 10.0}"
        end
      when DateTime, Time
        if profile == 40
          zone =
            if value.is_a?(DateTime)
              if value.offset == 0
                'Z'
              else
                secs = (value.offset * 86400).to_i
                sign = secs < 0 ? '-' : '+'
                format('%s%02d:%02d', sign, secs.abs / 3600, (secs.abs % 3600) / 60)
              end
            elsif value.is_a?(Time)
              # A Time carries an implementation-defined local zone; only
              # UTC is unambiguous. Non-UTC Time values are emitted as
              # floating so the machine's local zone is never substituted.
              value.utc? ? 'Z' : nil
            else
              nil # preserve a floating local time, do not invent a zone
            end
          encoded = format('%04d-%02d-%02dT%02d:%02d:%02d%s',
                          value.year, value.month, value.day,
                          value.hour, value.min, value.sec, zone.to_s)
          Vpim::DirectoryInfo::Field.create(name, encoded)
        else
          Vpim::DirectoryInfo::Field.create(name, value)
        end
      when Date
        if profile == 40
          Vpim::DirectoryInfo::Field.create(name, value.strftime('%Y-%m-%d'))
        else
          Vpim::DirectoryInfo::Field.create(name, value, { 'VALUE' => 'date' })
        end
      when ::String, String
        if profile == 40
          Vpim::DirectoryInfo::Field.create(name, Vpim.encode_text(value), { 'VALUE' => 'TEXT' })
        else
          Vpim::DirectoryInfo::Field.create(name, value)
        end
      when nil
        raise Vpim::Unencodeable, "#{name} value cannot be nil"
      else
        raise Vpim::Unencodeable, "cannot encode #{value.class} as #{name}"
      end
    end

    def self.encode_geo_field(geo, profile)
      case geo
      when Geo
        value = geo.value_type == 'uri' ? geo.uri.uri : geo.coordinates.join(';')
        params = geo.value_type == 'uri' ? { 'VALUE' => 'URI' } : { 'VALUE' => 'TEXT' }
        Vpim::DirectoryInfo::Field.create('GEO', value, params)
      when Array
        unless geo.size == 2 && geo.all? { |c| c.is_a?(Numeric) }
          raise Vpim::Unencodeable, 'GEO array must be [latitude, longitude]'
        end
        if profile == 40
          Vpim::DirectoryInfo::Field.create('GEO', format('geo:%s,%s', num(geo[0]), num(geo[1])),
                       { 'VALUE' => 'URI' })
        else
          Vpim::DirectoryInfo::Field.create('GEO', geo.map(&:to_f).join(';'))
        end
      when String, ::String
        uri = geo.to_s
        if profile == 40
          unless uri.downcase =~ %r{\Ageo:}
            raise Vpim::Unencodeable, 'GEO URI in vCard 4.0 must be a geo: URI'
          end
          Vpim::DirectoryInfo::Field.create('GEO', uri, { 'VALUE' => 'URI' })
        else
          Vpim::DirectoryInfo::Field.create('GEO', uri)
        end
      when Vpim::Attachment::Uri
        Vpim::DirectoryInfo::Field.create('GEO', geo.uri, { 'VALUE' => 'URI' })
      else
        raise Vpim::Unencodeable, "cannot encode #{geo.class} as GEO"
      end
    end

    def self.encode_tz_field(tz, profile)
      case tz
      when UtcOffset
        Vpim::DirectoryInfo::Field.create('TZ', tz.to_s, { 'VALUE' => 'UTC-OFFSET' })
      when DateAndOrTime
        Vpim::DirectoryInfo::Field.create('TZ', tz.to_s, { 'VALUE' => 'DATE-AND-OR-TIME' })
      when Vpim::Attachment::Uri
        if profile != 40
          raise Vpim::Unencodeable, 'TZ URI values require vCard 4.0'
        end
        Vpim::DirectoryInfo::Field.create('TZ', tz.uri, { 'VALUE' => 'URI' })
      when String, ::String
        s = tz.to_s
        if profile == 40 && s =~ %r{\A#{UriValue::SCHEME}:}
          Vpim::DirectoryInfo::Field.create('TZ', s, { 'VALUE' => 'URI' })
        else
          Vpim::DirectoryInfo::Field.create('TZ', s)
        end
      else
        raise Vpim::Unencodeable, "cannot encode #{tz.class} as TZ"
      end
    end

    def self.num(n)
      i = n.to_i
      i == n ? i.to_s : n.to_s
    end

    # A property that could not be converted losslessly. +field+ is the
    # original Field, +reason+ describes what can't be represented in the
    # target version, and +loss+ is 'omitted' (dropped) or 'converted'
    # (carried over in a degraded form).
    ConversionLoss = Struct.new(:field, :reason, :loss)

    # vCard 3.0 (and 2.1) properties with no meaning in vCard 4.0, and the
    # vCard 4.0 properties with no meaning in 2.1/3.0.
    REMOVED_IN_40 = %w[ LABEL MAILER AGENT PROFILE NAME ]
    REMOVED_IN_30 = %w[ ANNIVERSARY ]
    V4_ONLY_KINDS = %w[ date-and-or-time utc-offset ]

    module Conversion #:nodoc:all
      # Return a new Vcard converted to VERSION +target+ (21, 30 or 40),
      # together with an Array of ConversionLoss describing fields that
      # cannot be represented losslessly in the target version. Fields that
      # cannot be converted at all are omitted; fields that can be converted
      # only with loss are carried over and still listed.
      def convert_version(target)
        target = Vpim::Vcard.version_to_profile(target.to_s) unless target.is_a?(Integer)
        unless [21, 30, 40].include?(target)
          raise ArgumentError, "unsupported target version #{target.inspect}"
        end

        source = profile || 30
        if source == target
          return [self, []]
        end

        losses = []
        out_fields = []

        each do |f|
          name = f.name
          next if %w[BEGIN END VERSION].include?(name)

          converted, loss = Vpim::Vcard4.convert_field(f, source, target)
          if loss
            loss = [loss] unless loss.is_a?(Array)
            losses.concat(loss)
          end
          out_fields.concat(Array(converted)) if converted
        end

        all_fields = [Vpim::DirectoryInfo::Field.create('BEGIN', 'VCARD'),
                      Vpim::DirectoryInfo::Field.create('VERSION',
                        target == 40 ? '4.0' : (target == 21 ? '2.1' : '3.0'))]
        all_fields.concat(out_fields)
        all_fields << Vpim::DirectoryInfo::Field.create('END', 'VCARD')
        card = Vpim::Vcard.send(:new, all_fields, 'VCARD')

        [card, losses]
      end
    end

    Vpim::Vcard.send(:include, Conversion)

    def self.convert_field(field, source, target) #:nodoc:
      name = field.name
      kind = field.kind

      # Properties removed by the target version.
      removed = target == 40 ? REMOVED_IN_40 : REMOVED_IN_30
      if removed.include?(name)
        return [nil, Vpim::Vcard4::ConversionLoss.new(
                field, "#{name} does not exist in vCard #{target / 10.0}", 'omitted')]
      end

      if target == 40
        convert_to_v4(field, kind, source)
      else
        convert_to_v3(field, kind, target)
      end
    end

    def self.convert_to_v4(field, kind, source) #:nodoc:
      name = field.name
      f = field.copy
      losses = []

      # TYPE=pref -> standalone PREF (lossless, but normalize).
      types = f.pvalues('TYPE')
      if types && name != 'TEL'
        if types.any? { |t| t.downcase == 'pref' }
          remaining = types.reject { |t| t.downcase == 'pref' }
          if remaining.empty?
            f = remove_param(f, 'TYPE')
          else
            f['TYPE'] = remaining
          end
          f = with_param(f, 'PREF', '1') unless f.pvalue('PREF')
        end
      end

      # v2.1/v3.0 charset/encoding params are not in 4.0.
      %w[CHARSET].each do |p|
        if f.pvalues(p)
          f = remove_param(f, p)
          losses << ConversionLoss.new(field, "#{p} parameter has no vCard 4.0 equivalent", 'converted')
        end
      end

      case name
      when 'BDAY'
        convert_datetime_to_v4(f, losses)
      when 'ANNIVERSARY'
        # ANNIVERSARY exists only in 4.0; unreachable unless source odd.
        [f, losses]
      when 'TEL'
        value = f.value_raw
        if kind.nil? || kind == 'text'
          if value.to_s.downcase =~ %r{\A#{UriValue::SCHEME}:}
            f = with_value(f, value, 'URI')
          elsif value.to_s =~ /\A\s*\z/
            return [nil, ConversionLoss.new(field, 'empty TEL has no value', 'omitted')]
          else
            f = with_value(f, Vpim.encode_text(value), 'TEXT')
          end
        end
        # TYPE=pref (v3) becomes the standalone PREF parameter (v4).
        if (types = f.pvalues('TYPE')) && (types.index { |t| t.downcase == 'pref' })
          remaining = types.reject { |t| t.downcase == 'pref' }
          f = remaining.empty? ? remove_param(f, 'TYPE') : begin
            g = f
            g['TYPE'] = remaining
            g
          end
          f = with_param(f, 'PREF', '1') unless f.pvalue('PREF')
        end
        [f, losses]
      when 'GEO'
        if (kind || 'text') == 'text'
          parts = Vpim.decode_list(f.value_raw, ';') { |i| i.strip }
          if parts.size == 2
            f = with_value(f, format('geo:%s,%s', parts[0], parts[1]), 'URI')
          else
            losses << ConversionLoss.new(field, 'GEO is not a lat;long pair', 'omitted')
            return [nil, losses]
          end
        end
        [f, losses]
      when 'TZ'
        case kind
        when 'utc-offset', 'date-and-or-time'
          # already v4-typed
        else
          v = f.value_raw.to_s
          if v =~ %r{\A(?:--)?[+-]\d\d(?::?\d\d(?::?\d\d)?)?\z}
            f = with_value(f, v.sub(/\A--/, ''), 'UTC-OFFSET')
          elsif v =~ %r{\A#{UriValue::SCHEME}:}
            f = with_value(f, v, 'URI')
          else
            # free-form timezone name -> TEXT, information may be ambiguous
            losses << ConversionLoss.new(field,
              "TZ text \"#{v}\" kept as TEXT; semantic timezone is not normalized", 'converted')
          end
        end
        [f, losses]
      else
        # Drop v3 ENCODING=b on properties that v4 handles via data: URI
        # only when it is actually present; converting binary bodies is out
        # of scope, list the loss so callers aren't surprised.
        if f.encoding == 'B' || f.encoding == 'BASE64'
          losses << ConversionLoss.new(field,
            "inline encoded #{name} is not a vCard 4.0 data: URI", 'converted')
        end
        # Normalize TYPE=pref for every other property (TEL has its own
        # handling above).
        types2 = f.pvalues('TYPE')
        if types2 && types2.any? { |t| t.downcase == 'pref' }
          remaining = types2.reject { |t| t.downcase == 'pref' }
          if remaining.empty?
            f = remove_param(f, 'TYPE')
          else
            f['TYPE'] = remaining
          end
          f = with_param(f, 'PREF', '1') unless f.pvalue('PREF')
        end
        [f, losses]
      end
    end

    def self.convert_to_v3(field, kind, target) #:nodoc:
      name = field.name
      f = field.copy
      losses = []

      case name
      when 'BDAY'
        if kind == 'text'
          return [nil, ConversionLoss.new(field,
                  'BDAY;VALUE=TEXT cannot be represented in vCard 3.0', 'omitted')]
        end
        begin
          d = DateAndOrTime.decode(field.value_raw)
        rescue Vpim::InvalidEncodingError
          return [nil, ConversionLoss.new(field,
                  "BDAY value #{field.value_raw} is not a valid date", 'omitted')]
        end
        if d.hour
          return [nil, ConversionLoss.new(field,
                  'BDAY with a time component is not a vCard 3.0 BDAY', 'omitted')]
        end
        unless d.year && d.month && d.day
          return [nil, ConversionLoss.new(field,
                  'BDAY with a missing year/month/day cannot be represented in vCard 3.0', 'omitted')]
        end
        v3 = format('%04d%02d%02d', d.year, d.month, d.day)
        [with_value(f, v3, 'date'), losses]
      when 'TEL'
        if (kind || 'uri') == 'uri'
          v = f.value_raw.to_s
          if v =~ %r{\Atel:(.*)\z}i
            # Strip the scheme; extension and dialing parameters can't be
            # represented as a v3 free-text number.
            number = $1
            if number =~ /[;?]/
              loss = ConversionLoss.new(field,
                'tel: URI extension/parameters cannot be represented in vCard 3.0', 'converted')
              number = number.split(/[;?]/).first
              f = with_value(f, Vpim.encode_text(number), nil)
              if f.pvalue('PREF')
                f = remove_param(f, 'PREF')
                f.pvalue_iadd('TYPE', 'PREF')
              end
              return [f, [loss].concat(losses)]
            end
            f = with_value(f, Vpim.encode_text(number), nil)
          else
            return [nil, ConversionLoss.new(field,
                    "TEL;VALUE=URI #{v} is not a tel: URI", 'omitted')]
          end
        end
        # PREF=1 (v4) becomes TYPE=pref in v3.
        if f.pvalue('PREF')
          f = remove_param(f, 'PREF')
          f.pvalue_iadd('TYPE', 'PREF')
        end
        [f, losses]
      when 'GEO'
        if (kind || 'uri') == 'uri'
          begin
            geo = Geo.new('uri', f.value_raw)
          rescue Vpim::InvalidEncodingError
            return [nil, ConversionLoss.new(field, 'GEO URI is not a geo: URI', 'omitted')]
          end
          f = with_value(f, format('%s;%s', geo.latitude, geo.longitude), nil)
        end
        [f, losses]
      when 'TZ'
        case kind
        when 'uri'
          return [nil, ConversionLoss.new(field,
                  'TZ;VALUE=URI cannot be represented in vCard 3.0', 'omitted')]
        when 'utc-offset'
          f = with_value(f, field.value_raw.sub(/\A--/, ''), nil)
          losses << ConversionLoss.new(field,
            'TZ UTC-OFFSET converted to free text', 'converted')
        when 'date-and-or-time'
          return [nil, ConversionLoss.new(field,
                  'TZ;VALUE=DATE-AND-OR-TIME cannot be represented in vCard 3.0', 'omitted')]
        end
        [f, losses]
      else
        # PREF parameter -> TYPE=pref
        if f.pvalue('PREF')
          f = remove_param(f, 'PREF')
          f.pvalue_iadd('TYPE', 'pref')
        end
        [f, losses]
      end
    end

    def self.convert_datetime_to_v4(field, losses) #:nodoc:
      v = field.value_raw.to_s.strip
      # v4 extended form; keep as-is when it already conforms.
      if v =~ %r{\A\d{4}-\d{2}-\d{2}(T.*)?\z}
        begin
          DateAndOrTime.decode(v)
          return [field, losses]
        rescue Vpim::InvalidEncodingError
        end
      end
      # Try the permissive v3 heuristics (yyyymmdd, yyyy-mm-dd, ...).
      begin
        date = Vpim.decode_date_to_date(v)
      rescue Vpim::InvalidEncodingError
        begin
          dt = Vpim.decode_date_time_to_datetime(v)
          return [with_value(field, dt.strftime('%Y-%m-%dT%H:%M:%S'), nil), losses]
        rescue Vpim::InvalidEncodingError
          losses << ConversionLoss.new(field, "BDAY #{v} is not a valid date", 'omitted')
          return [nil, losses]
        end
      end
      [with_value(field, date.strftime('%Y-%m-%d'), nil), losses]
    end

    def self.with_value(field, value, kind) #:nodoc:
      params = {}
      field.each_param do |name, values|
        next if name == 'VALUE'
        params[name] = values
      end
      params['VALUE'] = kind if kind
      Vpim::DirectoryInfo::Field.create(field.name, value, params)
    end

    def self.remove_param(field, name) #:nodoc:
      params = {}
      field.each_param do |pname, values|
        params[pname] = values unless pname == name.upcase
      end
      Vpim::DirectoryInfo::Field.create(field.name, field.value_raw, params)
    end

    def self.with_param(field, name, value) #:nodoc:
      params = {}
      field.each_param do |pname, values|
        params[pname] = values
      end
      params[name] = value
      Vpim::DirectoryInfo::Field.create(field.name, field.value_raw, params)
    end
  end
end
