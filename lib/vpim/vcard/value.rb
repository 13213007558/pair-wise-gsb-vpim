# -*- encoding : utf-8 -*-
require 'date'
require 'uri'

module Vpim
  class Vcard < DirectoryInfo
    module Value
      class TypedValue < String
        attr_reader :value_type

        def initialize(value, value_type)
          @value_type = value_type.to_str.upcase
          super(value.to_str)
        end

        def encoded_value
          to_s
        end
      end

      class Text < TypedValue
        def self.parse(raw)
          new(Vpim.decode_text(raw), 'TEXT')
        end

        def self.encode(value)
          new(value.to_str, 'TEXT')
        end

        def encoded_value
          Vpim.encode_text(to_s)
        end
      end

      class Uri < TypedValue
        ABSOLUTE_URI = /\A[A-Za-z][A-Za-z0-9+.-]*:.*\z/m

        def self.parse(raw)
          unless raw =~ ABSOLUTE_URI && raw.chars.none? { |char| char =~ /[[:space:]]/ || char.ord < 0x20 }
            raise InvalidEncodingError, "URI value is not valid (#{raw})"
          end
          new(raw, 'URI')
        end

        def self.encode(value)
          parse(value.to_s)
        end

        def initialize(value, value_type='URI')
          super
        end

        def uri
          self
        end
      end

      class TelUri < Uri
        def self.parse(raw)
          uri = super
          unless uri =~ %r{\Atel:}i
            raise InvalidEncodingError, "TEL URI must use the tel scheme (#{raw})"
          end
          number = uri.sub(%r{\Atel:}i, '').split(/[?;]/).first.to_s
          if number.strip.empty?
            raise InvalidEncodingError, "TEL URI has no valid telephone number (#{raw})"
          end
          new(uri.to_s)
        end

        def extension
          if (match = to_s.match(/(?:\A|\?|&|;)ext=([^;&?]*)/i))
            URI.decode_www_form_component(match[1])
          end
        end
      end

      class GeoUri < Uri
        COORDINATE = /[+-]?(?:\d+(?:\.\d+)?|\.\d+)/

        def coordinates
          path = self.sub(%r{\Ageo:}i, '').split('?', 2).first
          match = path.match(/\A(#{COORDINATE}),(#{COORDINATE})(?:,#{COORDINATE})?\z/)
          match && [match[1].to_f, match[2].to_f]
        end
      end

      class UtcOffset < TypedValue
        OFFSET = /\A[+-](?:\d{4}(?:\d{2})?|\d{2}:\d{2}(?::\d{2})?)\z/

        def self.parse(raw)
          unless raw =~ OFFSET
            raise InvalidEncodingError, "UTC offset is not valid (#{raw})"
          end
          new(raw, 'UTC-OFFSET')
        end
      end

      class DateAndOrTime < TypedValue
        attr_reader :year, :month, :day, :hour, :minute, :second, :fraction, :zone

        FULL_DATE = /\A(?:(\d{4})(\d{2})(\d{2})|(\d{4})-(\d{2})-(\d{2}))\z/
        YEAR_MONTH = /\A(?:(\d{4})(\d{2})|(\d{4})-(\d{2}))\z/
        MONTH_DAY = /\A--(?:(\d{2})(\d{2})|(\d{2})-(\d{2}))\z/
        DAY_ONLY = /\A---(\d{2})\z/
        TIME = /\A(\d{2})(?:(\d{2})(?:(\d{2})(?:[.,](\d+))?)?|:(\d{2})(?::(\d{2})(?:[.,](\d+))?)?)(Z|[+-]\d{2}(?::?\d{2})?)?\z/

        def self.parse(raw)
          value = raw.to_s
          date_part = value
          time_part = nil
          if (match = value.match(/\A(.*)T(.+)\z/)) && match[1] != ''
            date_part = match[1]
            time_part = match[2]
          elsif value.match(/\A#{TIME.source}\z/)
            date_part = nil
            time_part = value
          end

          attrs = date_part.nil? ? {} : parse_date(date_part)
          attrs.update(parse_time(time_part)) if time_part
          raise InvalidEncodingError, "DATE-AND-OR-TIME value is not valid (#{raw})" unless attrs

          new(value, attrs)
        end

        def self.date(year: nil, month:, day:)
          if year.nil?
            new("--%02d-%02d" % [month, day], year: nil, month: month, day: day)
          else
            new("%04d-%02d-%02d" % [year, month, day], year: year, month: month, day: day)
          end
        end

        def self.year_month(year:, month:)
          new("%04d-%02d" % [year, month], year: year, month: month)
        end

        def self.year_only(year)
          new("%04d" % year, year: year)
        end

        def self.month_day(month, day)
          date(year: nil, month: month, day: day)
        end

        def self.time(hour:, minute: nil, second: nil, fraction: nil, zone: nil)
          value = "%02d" % hour
          if minute
            value << ":%02d" % minute
            if second
              value << ":%02d" % second
              value << fraction if fraction
            end
          end
          value << zone.to_s if zone
          new(value, hour: hour, minute: minute, second: second, fraction: fraction, zone: zone)
        end

        def self.date_time(year:, month:, day:, hour:, minute:, second: 0, fraction: nil, zone: nil)
          value = date(year: year, month: month, day: day).encoded_value + 'T' +
            time(hour: hour, minute: minute, second: second, fraction: fraction, zone: zone).encoded_value
          new(value, year: year, month: month, day: day, hour: hour, minute: minute,
              second: second, fraction: fraction, zone: zone)
        end

        def initialize(value, attrs = {})
          attrs.each do |name, attr_value|
            instance_variable_set("@#{name}", attr_value)
          end
          @fraction ||= nil
          super(value, 'DATE-AND-OR-TIME')
        end

        def year_missing?
          @year.nil?
        end

        def year_zero?
          @year == 0
        end

        def time?
          !@hour.nil?
        end

        def date?
          !@month.nil? || !@day.nil? || !@year.nil?
        end

        def timezone
          @zone
        end

        def to_date
          return nil unless @year && @month && @day
          Date.new(@year, @month, @day)
        end

        def self.parse_date(value)
          if (m = value.match(FULL_DATE))
            values = m[1] ? m.captures[0,3] : m.captures[3,3]
            return date_attrs(values[0].to_i, values[1].to_i, values[2].to_i)
          elsif (m = value.match(YEAR_MONTH))
            values = m[1] ? m.captures[0,2] : m.captures[2,2]
            return valid_date?(values[0].to_i, values[1].to_i, 1) &&
              { year: values[0].to_i, month: values[1].to_i }
          elsif value =~ /\A\d{4}\z/
            return { year: value.to_i }
          elsif (m = value.match(MONTH_DAY))
            values = m[1] ? m.captures[0,2] : m.captures[2,2]
            return valid_date?(2000, values[0].to_i, values[1].to_i) &&
              { year: nil, month: values[0].to_i, day: values[1].to_i }
          elsif (m = value.match(DAY_ONLY))
            return m[1].to_i.between?(1,31) ? { year: nil, month: nil, day: m[1].to_i } : nil
          end
          nil
        end

        def self.parse_time(value)
          match = value.match(TIME)
          return nil unless match
          values = match.captures
          if values[1]
            hour, minute, second, fraction, zone = values[0], values[1], values[2], values[3], values[7]
          else
            hour, minute, second, fraction, zone = values[0], values[4], values[5], values[6], values[7]
          end
          return nil unless hour.to_i.between?(0,23)
          return nil if minute && !minute.to_i.between?(0,59)
          return nil if second && !second.to_i.between?(0,60)
          { hour: hour.to_i, minute: minute && minute.to_i, second: second && second.to_i,
            fraction: fraction, zone: zone }
        end

        def self.date_attrs(year, month, day)
          valid_date?(year, month, day) ? { year: year, month: month, day: day } : nil
        end

        def self.valid_date?(year, month, day)
          Date.new(year, month, day)
          true
        rescue ArgumentError
          false
        end
      end

      class Registry
        TYPES = ['TEXT', 'URI', 'DATE-AND-OR-TIME', 'UTC-OFFSET'].freeze

        def initialize
          @extensions = {}
        end

        def register(name, *types)
          types = types.map { |type| normalize_type(type) }
          types = ['TEXT'] if types.empty?
          default = types.first
          unless types.include?(default)
            raise ArgumentError, "default VALUE type #{default} is not allowed"
          end
          @extensions[name.upcase] = { 'types' => types, 'default' => default }
        end

        def definition(name, version)
          standard = standard_definition(name, version)
          standard || @extensions[name.upcase]
        end

        private

        def normalize_type(type)
          normalized = type.to_s.upcase
          unless TYPES.include?(normalized)
            raise ArgumentError, "unsupported vCard VALUE type #{type}"
          end
          normalized
        end

        def standard_definition(name, version)
          case name
          when 'BDAY', 'ANNIVERSARY'
            if version == 40
              { 'types' => ['TEXT', 'URI', 'DATE-AND-OR-TIME'], 'default' => 'DATE-AND-OR-TIME' }
            else
              { 'types' => ['DATE', 'DATE-TIME'], 'default' => nil }
            end
          when 'TEL'
            version == 40 ? { 'types' => ['URI'], 'default' => 'URI' } : { 'types' => [], 'default' => nil }
          when 'GEO'
            version == 40 ? { 'types' => ['URI'], 'default' => 'URI' } : { 'types' => [], 'default' => nil }
          when 'TZ'
            if version == 40
              { 'types' => ['TEXT', 'URI', 'UTC-OFFSET'], 'default' => 'UTC-OFFSET' }
            else
              { 'types' => ['TEXT'], 'default' => nil }
            end
          when 'N', 'ADR'
            { 'types' => ['TEXT'], 'default' => 'TEXT' }
          end
        end
      end

      @registry = Registry.new

      def self.registry
        @registry
      end

      def self.register(name, *types)
        @registry.register(name, *types)
      end

      def self.decode(field, version)
        name = field.name.upcase
        definition = @registry.definition(name, version)
        type = effective_type(field, definition)
        parse_as(field.value_raw, type)
      end

      def self.effective_type(field, definition)
        type = field.kind && field.kind.upcase
        if definition
          allowed = definition['types']
          if type
            unless allowed.include?(type)
              raise InvalidEncodingError, "VALUE=#{field.kind} is not allowed for #{field.name}"
            end
          else
            type = definition['default']
          end
        end
        type ||= 'TEXT'
        type
      end

      def self.parse_as(raw, type)
        case type
        when 'URI'
          Uri.parse(raw)
        when 'TEXT'
          Text.parse(raw)
        when 'DATE-AND-OR-TIME'
          DateAndOrTime.parse(raw)
        when 'UTC-OFFSET'
          UtcOffset.parse(raw)
        else
          raise InvalidEncodingError, "VALUE=#{type} is not supported"
        end
      end
    end

    ConversionLoss = Struct.new(:name, :value_type, :reason, :field)
  end
end
