# -*- encoding : utf-8 -*-
module Vpim
  class Vcard < DirectoryInfo
    class VersionConverter
      Result = Struct.new(:card, :losses)
      class Result
        def to_ary
          [card, losses]
        end

        alias to_a to_ary

        def unrepresentable_fields
          losses.map(&:field)
        end
      end

      V4_ONLY = %w[KIND GENDER LANG XML].freeze

      def self.convert(card, target_version)
        new(card, target_version).convert
      end

      def initialize(card, target_version)
        @source = card
        @source_version = card.version_value
        @target_version = target_version
        @losses = []
      end

      def convert
        fields = []

        @source.each do |field|
          next if field.name?('BEGIN') || field.name?('END')

          if field.name?('VERSION')
            fields << DirectoryInfo::Field.create('VERSION', version_text)
          else
            converted = convert_field(field)
            fields.concat(converted) if converted
          end
        end

        result = Vcard.create(fields, @target_version)
        Result.new(result, @losses)
      end

      private

      def version_text
        { V21 => '2.1', V30 => '3.0', V40 => '4.0' }.fetch(@target_version)
      end

      def convert_field(field)
        name = field.name.upcase

        return nil if name == 'LABEL' && @target_version == V40

        case name
        when 'BDAY', 'ANNIVERSARY'
          convert_date_field(field)
        when 'TEL'
          convert_tel(field)
        when 'GEO'
          convert_geo(field)
        when 'TZ'
          convert_tz(field)
        when 'ADR'
          convert_address(field)
        when 'N', 'FN', 'EMAIL'
          convert_pref(field)
        else
          convert_generic(field)
        end
      end

      def convert_date_field(field)
        if @source_version == V40
          if @target_version == V40
            return [field.copy]
          end

          value = Value.decode(field, @source_version) rescue nil
          if value.is_a?(Value::DateAndOrTime)
            converted = legacy_date_value(value)
            return [DirectoryInfo::Field.create(field.name, converted)] if converted
          end
          loss(field, 'cannot represent v4 typed date value in vCard 2.1/3.0')
          nil
        else
          if @target_version == V40
            begin
              parsed = if field.kind && field.kind.upcase == 'DATE-TIME' || field.value_raw.include?('T')
                         date_time_from_legacy(field.value_raw)
                       else
                         date = Vpim.decode_date_to_date(field.value_raw)
                         Value::DateAndOrTime.date(year: date.year, month: date.month, day: date.day)
                       end
              [DirectoryInfo::Field.create(field.name, parsed, 'VALUE' => parsed.value_type)]
            rescue InvalidEncodingError
              loss(field, 'legacy date value is not a valid DATE-AND-OR-TIME value')
              nil
            end
          else
            [field.copy]
          end
        end
      end

      def legacy_date_value(value)
        return nil unless value.year && value.month && value.day && !value.time?
        if value.year.zero?
          '0000%02d%02d' % [value.month, value.day]
        else
          '%04d%02d%02d' % [value.year, value.month, value.day]
        end
      end

      def date_time_from_legacy(value)
        year, month, day, hour, minute, second, _fraction, zone = Vpim.decode_date_time(value)
        zone ||= nil
        Value::DateAndOrTime.new(
          '%04d-%02d-%02dT%02d:%02d:%02d%s' % [year, month, day, hour, minute, second, zone.to_s],
          year: year, month: month, day: day, hour: hour, minute: minute, second: second, zone: zone)
      end

      def convert_tel(field)
        if @target_version == V40
          uri = if @source_version == V40
                  field.value_raw.strip
                elsif field.value_raw =~ %r{\Atel:}i
                  field.value_raw.strip
                end

          if uri
            params = copy_params(field)
            params.delete('VALUE')
            params['VALUE'] = 'URI'
            if params['TYPE']
              types = params['TYPE'].reject { |type| type.casecmp?('PREF') }
              types.empty? ? params.delete('TYPE') : params['TYPE'] = types
            end
            params['PREF'] = '1' if field.pref?
            [DirectoryInfo::Field.create('TEL', Value::TelUri.parse(uri), params)]
          else
            loss(field, 'vCard 4.0 TEL requires a tel: URI')
            nil
          end
        else
          if field.value_raw =~ %r{\Atel:}i
            loss(field, 'tel: URI cannot be represented as a vCard 2.1/3.0 telephone number')
            nil
          else
            convert_pref(field)
          end
        end
      end

      def convert_geo(field)
        if @target_version == V40
          if field.kind && field.kind.upcase == 'URI'
            [field.copy]
          else
            begin
              parts = Vpim.decode_list(field.value_raw, ';') { |item| Float(item) }
            [DirectoryInfo::Field.create('GEO', Value::GeoUri.parse('geo:%f,%f' % parts), 'VALUE' => 'URI')]
            rescue ArgumentError, InvalidEncodingError
              loss(field, 'GEO cannot be represented as a geo URI')
              nil
            end
          end
        else
          if field.kind && field.kind.upcase != 'URI'
            return [field.copy]
          end

          uri = Value::GeoUri.parse(field.value_raw) rescue nil
          coordinates = uri && uri.coordinates
          if coordinates
            [DirectoryInfo::Field.create('GEO', '%f;%f' % coordinates)]
          else
            loss(field, 'geo URI cannot be represented as two floats')
            nil
          end
        end
      end

      def convert_tz(field)
        kind = field.kind && field.kind.upcase
        if @target_version == V40
          if kind == 'TEXT' || kind.nil?
            value = field.value_raw
            params = copy_params(field)
            params['VALUE'] = if value =~ %r{\A[+-]\d{4}\z}
                                'UTC-OFFSET'
                              elsif value =~ %r{\A[A-Za-z][A-Za-z0-9+.-]*:}
                                'URI'
                              else
                                'TEXT'
                              end
            [DirectoryInfo::Field.create('TZ', value, params)]
          else
            [field.copy]
          end
        else
          if kind == 'URI'
            loss(field, 'TZ URI cannot be represented in vCard 2.1/3.0')
            nil
          else
            params = copy_params(field)
            params.delete('VALUE') if params['VALUE']&.first&.upcase == 'UTC-OFFSET'
            [DirectoryInfo::Field.create('TZ', field.value_raw, params)]
          end
        end
      end

      def convert_address(field)
        params = copy_params(field)
        if @target_version == V40
          types = (params['TYPE'] || []).reject { |type| type.casecmp?('PREF') }
          if types.empty?
            params.delete('TYPE')
          else
            params['TYPE'] = types
          end
          params['PREF'] = '1' if field.pref?
          params['VALUE'] = 'TEXT'
        elsif field.pref?
          params['PREF']&.delete('1')
          params.delete('PREF') if params['PREF']&.empty?
          params['TYPE'] = ((params['TYPE'] || []) + ['pref']).uniq
          params.delete('VALUE')
        end
        params.delete('VALUE') if @target_version != V40
        [DirectoryInfo::Field.create('ADR', field.value_raw, params)]
      end

      def convert_pref(field)
        params = copy_params(field)
        if @target_version == V40
          types = (params['TYPE'] || []).reject { |type| type.casecmp?('PREF') }
          if types.empty?
            params.delete('TYPE')
          else
            params['TYPE'] = types
          end
          params['PREF'] = '1' if field.pref? && !params.key?('PREF')
          params['VALUE'] = 'TEXT' if field.name.upcase == 'N'
        elsif @source_version == V40 && field.pvalue('PREF')
          params.delete('PREF')
          params['TYPE'] = ((params['TYPE'] || []) + ['pref']).uniq
        end
        params.delete('VALUE') if @target_version != V40 && ['N', 'FN', 'EMAIL'].include?(field.name.upcase)
        [DirectoryInfo::Field.create(field.name, field.value_raw, params)]
      end

      def convert_generic(field)
        name = field.name.upcase
        kind = field.kind && field.kind.upcase

        if @source_version == V40 && @target_version != V40
          if V4_ONLY.include?(name)
            loss(field, "#{name} is a vCard 4.0-only property")
            return nil
          end
          if name =~ /\AX-/ && kind == 'URI'
            loss(field, 'URI extension value cannot be represented in vCard 2.1/3.0')
            return nil
          end
          if name =~ /\AX-/ && kind == 'DATE-AND-OR-TIME'
            loss(field, 'DATE-AND-OR-TIME extension value cannot be represented in vCard 2.1/3.0')
            return nil
          end
        end

        [field.copy]
      end

      def copy_params(field)
        params = {}
        field.each_param do |name, values|
          params[name] = values.dup
        end
        params
      end

      def loss(field, reason)
        @losses << ConversionLoss.new(field.name.upcase, field.kind && field.kind.upcase, reason, field)
      end
    end

    def convert_version(target_version)
      target = { 21 => V21, 30 => V30, 40 => V40 }.fetch(target_version)
      VersionConverter.convert(self, target)
    end

    def Vcard.convert(card, target_version)
      card.convert_version(target_version)
    end
  end
end
