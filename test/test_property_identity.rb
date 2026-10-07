# -*- encoding : utf-8 -*-
#!/usr/bin/env ruby

require 'test/unit'
require 'vpim/property_identity'

PIField = Vpim::DirectoryInfo::Field

class TestPropertyIdentity < Test::Unit::TestCase

  def test_groups_pids_by_client_uri_and_object_number
    left = [
      PIField.create('UID', 'contact-1'),
      PIField.create('CLIENTPIDMAP', '1;urn:uuid:device-a'),
      PIField.create('EMAIL', 'same@example.com', 'PID' => '1.10')
    ]
    right = [
      PIField.create('UID', 'contact-1'),
      PIField.create('CLIENTPIDMAP', '8;urn:uuid:device-a'),
      PIField.create('EMAIL', 'different@example.com', 'PID' => '8.10')
    ]

    result = Vpim::PropertyIdentity.normalize([left, right])

    assert_equal(true, result[:ok])
    assert_equal(1, result[:groups].length)
    assert_equal([left[2], right[2]], result[:groups].first[:properties])
    assert_equal([{:uri => 'urn:uuid:device-a', :object => 10}],
      result[:groups].first[:identities])
    assert_equal([1, 1], result[:client_maps].collect { |map| map[:client] })
    assert_equal([1, 8], result[:client_maps].collect { |map| map[:local_client] })
    assert_equal('property-content-conflict', result[:conflicts].first[:type])
  end

  def test_pid_parameters_do_not_count_as_content_conflicts
    copies = [
      [PIField.create('UID', 'contact-1a'),
       PIField.create('CLIENTPIDMAP', '1;urn:uuid:source'),
       PIField.create('EMAIL', 'same@example.com', 'TYPE' => 'work', 'PID' => '1.10')],
      [PIField.create('UID', 'contact-1a'),
       PIField.create('CLIENTPIDMAP', '8;urn:uuid:source'),
       PIField.create('EMAIL', 'same@example.com', 'TYPE' => 'work', 'PID' => '8.10')]
    ]

    result = Vpim.normalize_property_identities(copies)

    assert_equal(1, result[:groups].length)
    assert_equal(false, result[:groups].first[:conflict])
    assert_equal([], result[:conflicts])
    assert_equal(1, result[:pids].first[:group])
    assert_equal(1, result[:pids].last[:group])
  end

  def test_group_numbering_is_stable_when_local_numbers_are_renumbered
    copy_one = [
      PIField.create('UID', 'contact-2'),
      PIField.create('CLIENTPIDMAP', '1;urn:uuid:source'),
      PIField.create('EMAIL', 'first@example.com', 'PID' => '1.1'),
      PIField.create('EMAIL', 'second@example.com', 'PID' => '1.2')
    ]
    copy_two = [
      PIField.create('UID', 'contact-2'),
      PIField.create('CLIENTPIDMAP', '9;urn:uuid:source'),
      PIField.create('EMAIL', 'second@example.com', 'PID' => '9.2'),
      PIField.create('EMAIL', 'first@example.com', 'PID' => '9.1')
    ]

    original = Vpim::PropertyIdentity.normalize([copy_one, copy_two])
    reordered = Vpim::PropertyIdentity.normalize([copy_two, copy_one])

    original_groups = original[:groups].collect { |group| group[:identities] }
    reordered_groups = reordered[:groups].collect { |group| group[:identities] }
    assert_equal(original_groups, reordered_groups)
    assert_equal([1, 2], reordered[:pid_map].collect { |entry| entry[:group] })
    assert_equal([1, 2], reordered[:groups].collect { |group| group[:number] })
  end

  def test_multiple_pids_union_overlapping_properties
    first = [
      PIField.create('UID', 'contact-3'),
      PIField.create('CLIENTPIDMAP', '1;urn:uuid:source'),
      PIField.create('TEL', '+1 555 0100', 'PID' => ['1.1', '1.2'])
    ]
    second = [
      PIField.create('UID', 'contact-3'),
      PIField.create('CLIENTPIDMAP', '2;urn:uuid:source'),
      PIField.create('TEL', '+1 555 0100', 'PID' => ['2.2', '2.3'])
    ]
    third = [
      PIField.create('UID', 'contact-3'),
      PIField.create('CLIENTPIDMAP', '3;urn:uuid:source'),
      PIField.create('TEL', '+1 555 0100', 'PID' => '3.3')
    ]

    result = Vpim::PropertyIdentity.normalize([first, second, third])

    assert_equal(1, result[:groups].length)
    assert_equal([1, 2, 3], result[:groups].first[:identities].collect { |id| id[:object] })
  end

  def test_equal_text_with_different_stable_identities_stays_separate
    first = [
      PIField.create('UID', 'contact-4'),
      PIField.create('CLIENTPIDMAP', '1;urn:uuid:source-a'),
      PIField.create('TEL', '+1 555 0100', 'PID' => '1.1')
    ]
    second = [
      PIField.create('UID', 'contact-4'),
      PIField.create('CLIENTPIDMAP', '1;urn:uuid:source-b'),
      PIField.create('TEL', '+1 555 0100', 'PID' => '1.1')
    ]

    result = Vpim::PropertyIdentity.normalize([first, second])

    assert_equal(2, result[:groups].length)
    assert_equal([[first[2]], [second[2]]], result[:groups].collect { |group| group[:properties] })
    assert_equal([], result[:conflicts])
  end

  def test_properties_without_pid_remain_independent_candidates
    copies = [
      [PIField.create('UID', 'contact-5'), PIField.create('EMAIL', 'only@example.com')],
      [PIField.create('UID', 'contact-5'), PIField.create('EMAIL', 'only@example.com')]
    ]

    result = Vpim::PropertyIdentity.normalize(copies)

    assert_equal(2, result[:groups].length)
    assert_equal([false, false], result[:groups].collect { |group| group[:resolved] })
    assert_equal([], result[:conflicts])
  end

  def test_missing_client_pidmap_is_reported_and_does_not_group
    copies = [
      [PIField.create('UID', 'contact-6'), PIField.create('EMAIL', 'a@example.com', 'PID' => '4.1')],
      [PIField.create('UID', 'contact-6'),
       PIField.create('CLIENTPIDMAP', '4;urn:uuid:source'),
       PIField.create('EMAIL', 'a@example.com', 'PID' => '4.1')]
    ]

    result = Vpim::PropertyIdentity.normalize(copies)
    issue = result[:issues].detect { |item| item[:type] == 'missing-client-pidmap' }

    assert_not_nil(issue)
    assert_equal(4, issue[:client_number])
    assert_equal(2, result[:groups].length)
  end

  def test_conflicting_client_pidmap_does_not_resolve_pid
    copies = [
      [PIField.create('UID', 'contact-6a'),
       PIField.create('CLIENTPIDMAP', '1;urn:uuid:source-a'),
       PIField.create('CLIENTPIDMAP', '1;urn:uuid:source-b'),
       PIField.create('EMAIL', 'a@example.com', 'PID' => '1.5')],
      [PIField.create('UID', 'contact-6a'),
       PIField.create('CLIENTPIDMAP', '1;urn:uuid:source-a'),
       PIField.create('EMAIL', 'a@example.com', 'PID' => '1.5')]
    ]

    result = Vpim::PropertyIdentity.normalize(copies)

    assert_equal(2, result[:groups].length)
    assert_equal('client-pidmap-conflict', result[:conflicts].first[:type])
    assert_equal('ambiguous-client-pidmap', result[:issues].first[:type])
    ambiguous_map = result[:client_maps].detect { |map| !map[:resolved] }
    assert_not_nil(ambiguous_map)
    assert_nil(ambiguous_map[:client])
  end

  def test_accepts_decoded_fields_without_vcard_codec
    copies = [
      [PIField.decode('UID:contact-8'), PIField.decode('CLIENTPIDMAP:2;urn:uuid:source'),
       PIField.decode('EMAIL;PID=2.3:a@example.com')],
      [PIField.decode('UID:contact-8'), PIField.decode('CLIENTPIDMAP:7;urn:uuid:source'),
       PIField.decode('EMAIL;PID=7.3:a@example.com')]
    ]

    result = Vpim::PropertyIdentity.normalize_field_copies(copies)

    assert_equal(1, result[:groups].length)
    assert_equal(3, result[:groups].first[:identities].first[:object])
  end

  def test_accepts_explicit_uid_and_a_single_field_array
    fields = [PIField.create('CLIENTPIDMAP', '4;urn:uuid:source'),
              PIField.create('EMAIL', 'a@example.com', 'PID' => '4.9')]

    result = Vpim::PropertyIdentity.normalize('contact-9', fields)

    assert_equal(true, result[:ok])
    assert_equal('contact-9', result[:uid])
    assert_equal(1, result[:groups].length)
  end

  def test_inconsistent_uids_are_reported
    copies = [
      [PIField.create('UID', 'contact-a'), PIField.create('EMAIL', 'a@example.com')],
      [PIField.create('UID', 'contact-b'), PIField.create('EMAIL', 'a@example.com')]
    ]

    result = Vpim::PropertyIdentity.normalize(copies)

    assert_equal(false, result[:ok])
    assert_equal('uid-mismatch', result[:conflicts].first[:type])
    assert_equal([], result[:groups])
  end

  def test_missing_uid_is_reported
    copies = [
      [PIField.create('EMAIL', 'a@example.com')],
      [PIField.create('UID', 'contact-b'), PIField.create('EMAIL', 'a@example.com')]
    ]

    result = Vpim::PropertyIdentity.normalize(copies)

    assert_equal(false, result[:ok])
    assert_equal('missing-uid', result[:issues].first[:type])
    assert_equal(0, result[:issues].first[:ref][:copy])
  end

  def test_bare_pids_cannot_be_used_as_cross_device_identities
    copies = [
      [PIField.create('UID', 'contact-7'), PIField.create('TEL', '+1 555 0100', 'PID' => '1')],
      [PIField.create('UID', 'contact-7'), PIField.create('TEL', '+1 555 0100', 'PID' => '1')]
    ]

    result = Vpim::PropertyIdentity.normalize(copies)

    assert_equal(2, result[:groups].length)
    assert_equal('missing-client-pid', result[:issues].first[:type])
  end
end
