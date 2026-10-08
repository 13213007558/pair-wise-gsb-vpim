# -*- encoding : utf-8 -*-
#!/usr/bin/env ruby

require 'vpim/vcard'
require 'test/unit'
require 'date'

include Vpim

class TestVcard4 < Test::Unit::TestCase

  # The card described by the task: a month/day-only birthday, a tel: URI
  # carrying an extension, and an address whose component contains an
  # escaped list separator.
  CARD = <<'EOF'
BEGIN:VCARD
VERSION:4.0
N:Doe;Jane;;;
FN:Jane Doe
BDAY:--0229
TEL;TYPE=work;VALUE=URI;PREF=1:tel:+1-555-555-1234;ext=987
ADR;TYPE=home:;;123 Main\, Suite 4;Town;ON;M1M 1M1;Canada
GEO:geo:37.3323,-122.0312
TZ;VALUE=UTC-OFFSET:+08:00
ANNIVERSARY:20100601
END:VCARD
EOF

  def test_profile
    card = Vpim::Vcard.decode(CARD).first
    assert_equal(40, card.version)
    assert_equal(40, card.profile)
  end

  def test_birthday_month_day_has_no_year
    card = Vpim::Vcard.decode(CARD).first
    bday = card.birthday
    assert_kind_of(Vpim::Vcard4::DateAndOrTime, bday)
    assert_nil(bday.year)
    assert_equal(2, bday.month)
    assert_equal(29, bday.day)
    assert_equal('--0229', bday.to_s)
  end

  def test_missing_year_is_distinct_from_year_zero
    missing = Vpim::Vcard4::DateAndOrTime.decode('--0229')
    zero    = Vpim::Vcard4::DateAndOrTime.decode('00000229')

    assert_nil(missing.year)
    assert_equal(0, zero.year)
    refute_equal(missing.to_s, zero.to_s)
    assert_equal('--02-29', missing.encode)
    assert_equal('0000-02-29', zero.encode)
  end

  def test_bday_text_and_bad_uri
    text_bday = <<'EOF'
BEGIN:VCARD
VERSION:4.0
N:A;B;;;
FN:B
BDAY;VALUE=TEXT:circa 1800
END:VCARD
EOF
    card = Vpim::Vcard.decode(text_bday).first
    assert_kind_of(String, card.birthday)
    assert_equal('circa 1800', card.birthday)

    bad = text_bday.sub('BDAY;VALUE=TEXT:circa 1800',
                        'TEL;VALUE=URI:not a uri')
    assert_raise(Vpim::InvalidEncodingError) do
      Vpim::Vcard.decode(bad)
    end
  end

  def test_year_zero_round_trips_and_is_not_omitted
    card = Vpim::Vcard::Maker.make4 do |m|
      m.name { |n| n.given = 'X' }
      m.birthday = Vpim::Vcard4::DateAndOrTime.new(year: 0, month: 2, day: 29)
    end
    bday = Vpim::Vcard.decode(card.encode(0)).first.birthday
    assert_equal(0, bday.year)
    assert_equal('0000-02-29', bday.to_s)
  end

  def test_tel_uri_round_trip_preserves_extension_and_type
    card = Vpim::Vcard.decode(CARD).first
    tel = card.telephone
    assert_kind_of(Vpim::Vcard::Telephone, tel)
    assert_equal('uri', tel.value_type)
    assert_equal('tel:+1-555-555-1234;ext=987', tel.to_str)
    assert(tel.preferred)
    assert(tel.location.include?('work'))

    # The whole URI, including the extension, survives write -> read.
    regenerated = Vpim::Vcard.decode(card.encode(0)).first
    tel2 = regenerated.telephone
    assert_equal('uri', tel2.value_type)
    assert_equal('tel:+1-555-555-1234;ext=987', tel2.to_str)
    assert(tel2.preferred)
  end

  def test_address_escaped_separator_is_a_component_list
    card = Vpim::Vcard.decode(CARD).first
    adr = card.address
    assert_equal('123 Main, Suite 4', adr.street)
    assert_equal(['123 Main', ' Suite 4'], adr.components[2])
    assert_equal(['Town'], adr.components[3])

    regenerated = Vpim::Vcard.decode(card.encode(0)).first
    assert_match(/123 Main\\, Suite 4/, regenerated.encode(0))
    assert_equal('123 Main, Suite 4', regenerated.address.street)
    assert_equal(['123 Main', ' Suite 4'], regenerated.address.components[2])
  end

  def test_full_round_trip_preserves_types_and_defaults
    card = Vpim::Vcard.decode(CARD).first
    encoded = card.encode(0)
    card2 = Vpim::Vcard.decode(encoded).first

    assert_equal(40, card2.version)
    assert_nil(card2.birthday.year)
    assert_equal('uri', card2.telephone.value_type)

    geo = card2.geo
    assert_kind_of(Vpim::Vcard4::Geo, geo)
    assert_equal('uri', geo.value_type)
    assert_in_delta(37.3323, geo.latitude, 1e-9)
    assert_in_delta(-122.0312, geo.longitude, 1e-9)

    tz = card2.tz
    assert_kind_of(Vpim::Vcard4::UtcOffset, tz)
    assert_equal('+08:00', tz.to_s)

    ann = card2.anniversary
    assert_kind_of(Vpim::Vcard4::DateAndOrTime, ann)
    assert_equal(2010, ann.year)
  end

  def test_floating_time_keeps_no_zone
    floating = Vpim::Vcard4::DateAndOrTime.decode('1985-04-12T23:59:59')
    assert_nil(floating.zone)
    assert_equal('1985-04-12T23:59:59', floating.encode)

    zoned = Vpim::Vcard4::DateAndOrTime.decode('1985-04-12T23:59:59Z')
    assert_equal('Z', zoned.zone)
    assert_equal('1985-04-12T23:59:59Z', zoned.encode)
  end

  def test_maker_does_not_invent_zone_for_time
    require 'time'
    card = Vpim::Vcard::Maker.make4 do |m|
      m.name { |n| n.given = 'X' }
      # Non-UTC Time: no numeric zone is invented.
      m.birthday = Time.new(1985, 4, 12, 23, 59, 59)
    end
    assert_match(/^BDAY:\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}$/,
                 card.encode(0))

    # UTC Time keeps its Z.
    card2 = Vpim::Vcard::Maker.make4 do |m|
      m.name { |n| n.given = 'X' }
      m.birthday = Time.utc(1985, 4, 12, 23, 59, 59)
    end
    assert_match(/Z$/, card2.field('BDAY').value_raw)

    # DateTime with an explicit offset keeps it.
    card3 = Vpim::Vcard::Maker.make4 do |m|
      m.name { |n| n.given = 'X' }
      m.birthday = DateTime.new(1985, 4, 12, 23, 59, 59, Rational(5 * 60 + 30, 1440))
    end
    assert_match(/\+05:30$/, card3.field('BDAY').value_raw)
  end

  def test_invalid_version_value_combinations_are_rejected
    [
      ['3.0', 'BDAY;VALUE=DATE-AND-OR-TIME:--0229'],
      ['3.0', 'TEL;VALUE=URI:tel:+1-555'],
      ['3.0', 'GEO;VALUE=URI:geo:1,2'],
      ['4.0', 'TEL;VALUE=DATE-AND-OR-TIME:--0229'],
      ['4.0', 'BDAY;VALUE=URI:http://example.com'],
      ['4.0', 'GEO:37.3;-122.0'],
      ['4.0', 'N;VALUE=URI:x'],
    ].each do |version, line|
      src = "BEGIN:VCARD\nVERSION:#{version}\n#{line}\nN:A;B;;;\nFN:B\nEND:VCARD\n"
      assert_raise(Vpim::InvalidEncodingError, "expected error for #{line}") do
        Vpim::Vcard.decode(src)
      end
    end
  end

  def test_v21_and_v30_entrypoints_keep_behaviour
    v21 = <<'EOF'
BEGIN:VCARD
VERSION:2.1
N:Doe;Jane
FN:Jane Doe
TEL;VOICE:+1 555 1234
END:VCARD
EOF
    card = Vpim::Vcard.decode(v21).first
    assert_equal(21, card.profile)
    assert_equal('text', card.telephones.first.value_type)
    assert_equal('+1 555 1234', card.telephones.first.to_str)

    # A plain v3 tel is still TEXT, not a URI.
    v30 = "BEGIN:VCARD\nVERSION:3.0\nN:A;B;;;\nFN:B\nTEL:+1\nEND:VCARD\n"
    c30 = Vpim::Vcard.decode(v30).first
    assert_equal('text', c30.telephones.first.value_type)
  end

  def test_make4_generates_typed_values
    card = Vpim::Vcard::Maker.make4 do |m|
      m.name { |n| n.given = 'Jane'; n.family = 'Doe' }
      m.birthday = Vpim::Vcard4::DateAndOrTime.new(month: 2, day: 29)
      m.add_tel('tel:+1-555-555-1234;ext=987') { |t| t.preferred = true }
      m.add_addr do |a|
        a.street = '123 Main, Suite 4'
        a.locality = 'Town'
      end
      m.add_geo([37.3323, -122.0312])
      m.add_tz(Vpim::Vcard4::UtcOffset.new('+08:00'))
      m.anniversary = Date.new(2010, 6, 1)
    end

    s = card.encode(0)
    assert_match(/^VERSION:4\.0$/, s)
    assert_match(/^BDAY:--02-29$/, s)
    assert_match(/^TEL;VALUE=URI;PREF=1:tel:.*ext=987/, s)
    assert_match(/123 Main\\, Suite 4/, s)
    assert_match(/^GEO;VALUE=URI:geo:/, s)
    assert_match(/^TZ;VALUE=UTC-OFFSET:\+08:00$/, s)
    assert_match(/^ANNIVERSARY:2010-06-01$/, s)
  end

  def test_create4
    card = Vpim::Vcard.create4
    assert_equal(40, card.profile)
  end

  def test_extension_can_register_its_value_type
    Vpim::Vcard4.register_property('X-SPONSOR',
      40 => { 'default' => 'uri', 'allowed' => ['text', 'uri'] })

    src = <<'EOF'
BEGIN:VCARD
VERSION:4.0
N:A;B;;;
FN:B
X-SPONSOR;VALUE=URI:https://example.com/
END:VCARD
EOF
    card = Vpim::Vcard.decode(src).first
    assert_equal('uri', card.field('X-SPONSOR').kind)
    sponsor = card.value('X-SPONSOR')
    assert_kind_of(Vpim::Attachment::Uri, sponsor)
    assert_equal('https://example.com/', sponsor.uri)

    # An unallowed type is rejected.
    bad = src.sub('VALUE=URI', 'VALUE=DATE-AND-OR-TIME')
    assert_raise(Vpim::InvalidEncodingError) do
      Vpim::Vcard.decode(bad)
    end
  end

  def test_convert_v4_to_v3_reports_losses
    card = Vpim::Vcard.decode(CARD).first
    v3, losses = card.convert_version(30)

    assert_equal(30, v3.profile)
    names = losses.map { |l| l.field.name }
    assert_include(names, 'BDAY')
    assert_include(names, 'ANNIVERSARY')
    assert_include(names, 'TEL')

    # The incomplete birthday and anniversary cannot be represented and
    # are omitted.
    assert_nil(v3.field('BDAY'))
    assert_nil(v3.field('ANNIVERSARY'))

    # The tel URI survives only as a free-text number; the extension is
    # reported as a loss.
    assert_equal('+1-555-555-1234', v3.telephones.first.to_str)
    tel_loss = losses.find { |l| l.field.name == 'TEL' }
    assert_match(/extension/i, tel_loss.reason)

    # GEO returns to the v3 float pair.
    assert_equal([37.3323, -122.0312], v3.geo)
  end

  def test_convert_v3_to_v4
    v3 = <<'EOF'
BEGIN:VCARD
VERSION:3.0
N:Doe;Jane;;;
FN:Jane Doe
BDAY;VALUE=date:19700714
TEL;TYPE=PREF:+1 555 1234
GEO:37.3;-122.0
TZ:-05:00
END:VCARD
EOF
    card = Vpim::Vcard.decode(v3).first
    v4, losses = card.convert_version(40)

    assert_equal(40, v4.profile)
    assert_equal('1970-07-14', v4.field('BDAY').value_raw)
    assert_equal('text', v4.telephones.first.value_type)
    assert_match(/\Ageo:/, v4.geo.uri.uri)
    assert_equal('utc-offset', v4.field('TZ').kind)
    assert(losses.none? { |l| l.field.name == 'BDAY' })
  end

  def test_convert_round_trip_full_date_bday_is_lossless
    v4src = <<'EOF'
BEGIN:VCARD
VERSION:4.0
N:A;B;;;
FN:B
BDAY:1970-07-14
END:VCARD
EOF
    card = Vpim::Vcard.decode(v4src).first
    v3, losses = card.convert_version(30)
    assert(losses.none? { |l| l.field.name == 'BDAY' })
    assert_equal('19700714', v3.field('BDAY').value_raw)
  end

end
