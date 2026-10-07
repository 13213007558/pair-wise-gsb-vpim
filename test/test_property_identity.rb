#!/usr/bin/env ruby

require 'test/unit'
require 'vpim/field'
require 'vpim/property_identity'

Field = Vpim::DirectoryInfo::Field

class TestPropertyIdentity < Test::Unit::TestCase
  URI_A = 'urn:uuid:device-a'
  URI_B = 'urn:uuid:device-b'

  def fields(*lines)
    lines.map { |l| Field.decode(l) }
  end

  def identity(uri, pid)
    Vpim::PropertyIdentity::Identity.new(uri, pid)
  end

  # Sorted, comparable description of the grouping: which copies contribute
  # which properties to each group.
  def signatures(result)
    result.groups.map do |g|
      g.members.map { |m| [ m.copy_index, m.field.name, m.field.value ] }.sort
    end.sort_by(&:inspect)
  end

  def test_identity_uses_client_part_and_clientpidmap_uri
    copy_a = fields(
      'UID:urn:uuid:contact-1',
      'CLIENTPIDMAP:1;urn:uuid:device-a',
      'CLIENTPIDMAP:2;urn:uuid:device-b',
      'EMAIL;PID=1.1:a@example.com',
      'TEL;PID=1.2:+1-555-0100'
    )
    # Device B numbers its CLIENTPIDMAP entries the other way around, and
    # its PID source parts follow its own numbering.
    copy_b = fields(
      'UID:urn:uuid:contact-1',
      'CLIENTPIDMAP:1;urn:uuid:device-b',
      'CLIENTPIDMAP:2;urn:uuid:device-a',
      'EMAIL;PID=1.2:a@example.com',
      'TEL;PID=1.1:+1-555-0100'
    )

    result = Vpim::PropertyIdentity.normalize([ copy_a, copy_b ])

    assert_equal('urn:uuid:contact-1', result.uid)
    assert_equal([], result.issues)

    groups = result.identified_groups
    assert_equal(2, groups.size)

    email_group = groups.detect { |g| g.identities.include?(identity(URI_A, 1)) }
    assert_not_nil(email_group)
    assert_equal([ 0, 1 ], email_group.copy_indexes)

    tel_group = groups.detect { |g| g.identities.include?(identity(URI_B, 1)) }
    assert_not_nil(tel_group)
    assert_equal([ 0, 1 ], tel_group.copy_indexes)

    # Normalized numbering covers exactly the two identities.
    assert_equal(
      { identity(URI_A, 1) => 1, identity(URI_B, 1) => 2 },
      result.mapping
    )
  end

  def test_renumbering_device_local_numbers_keeps_groups
    copy_a = fields(
      'UID:urn:uuid:contact-1',
      'CLIENTPIDMAP:1;urn:uuid:device-a',
      'CLIENTPIDMAP:2;urn:uuid:device-b',
      'EMAIL;PID=1.1:a@example.com',
      'TEL;PID=3.2:+1-555-0100',
      'URL;PID=7.2:http://example.com/'
    )
    copy_b = fields(
      'UID:urn:uuid:contact-1',
      'CLIENTPIDMAP:1;urn:uuid:device-b',
      'CLIENTPIDMAP:2;urn:uuid:device-a',
      'EMAIL;PID=1.2:a@example.com',
      'TEL;PID=3.1:+1-555-0100',
      'URL;PID=7.1:http://example.com/'
    )

    before = Vpim::PropertyIdentity.normalize([ copy_a, copy_b ])

    # Device B reorders its CLIENTPIDMAP numbering (and the matching PID
    # source parts) before the next sync run.
    copy_b_renumbered = fields(
      'UID:urn:uuid:contact-1',
      'CLIENTPIDMAP:5;urn:uuid:device-a',
      'CLIENTPIDMAP:9;urn:uuid:device-b',
      'EMAIL;PID=1.5:a@example.com',
      'TEL;PID=3.9:+1-555-0100',
      'URL;PID=7.9:http://example.com/'
    )

    after = Vpim::PropertyIdentity.normalize([ copy_a, copy_b_renumbered ])

    assert_equal(signatures(before), signatures(after))
    assert_equal(before.mapping, after.mapping)
  end

  def test_same_text_different_identity_not_merged
    copy = fields(
      'UID:urn:uuid:contact-1',
      'CLIENTPIDMAP:1;urn:uuid:device-a',
      'TEL;PID=1.1:+1-555-0100',
      'TEL;PID=2.1:+1-555-0100'
    )

    result = Vpim::PropertyIdentity.normalize([ copy ])
    groups = result.identified_groups

    assert_equal(2, groups.size)
    assert(groups.all? { |g| g.members.size == 1 })
  end

  def test_multiple_pids_on_one_property_union_groups
    copy_a = fields(
      'UID:urn:uuid:contact-1',
      'CLIENTPIDMAP:1;urn:uuid:device-a',
      'CLIENTPIDMAP:2;urn:uuid:device-b',
      'EMAIL;PID=1.1,4.2:a@example.com'
    )
    copy_b = fields(
      'UID:urn:uuid:contact-1',
      'CLIENTPIDMAP:1;urn:uuid:device-b',
      'CLIENTPIDMAP:2;urn:uuid:device-a',
      'EMAIL;PID=4.1:a@example.com',
      'EMAIL;PID=1.2:a@example.com'
    )

    result = Vpim::PropertyIdentity.normalize([ copy_a, copy_b ])
    groups = result.identified_groups

    # Both identities land on one property in copy A, so everything merges.
    assert_equal(1, groups.size)
    assert_equal(3, groups.first.members.size)
    assert_equal(
      [ identity(URI_A, 1), identity(URI_B, 4) ].sort,
      groups.first.identities.sort
    )
  end

  def test_property_without_pid_is_independent_candidate
    copy = fields(
      'UID:urn:uuid:contact-1',
      'CLIENTPIDMAP:1;urn:uuid:device-a',
      'NOTE:see you soon',
      'NOTE:see you soon'
    )

    result = Vpim::PropertyIdentity.normalize([ copy ])

    assert_equal([], result.identified_groups)
    assert_equal(2, result.candidates.size)
    assert(result.candidates.all? { |g| g.members.size == 1 })
    assert(result.candidates.all? { |g| g.number.nil? })
  end

  def test_missing_clientpidmap_entry_is_explained
    copy = fields(
      'UID:urn:uuid:contact-1',
      'CLIENTPIDMAP:1;urn:uuid:device-a',
      'EMAIL;PID=1.3:a@example.com'
    )

    result = Vpim::PropertyIdentity.normalize([ copy ])

    assert_equal(1, result.issues.size)
    issue = result.issues.first
    assert_equal(:missing_clientpidmap_entry, issue.reason)
    assert_equal(0, issue.copy_index)
    assert_match(/source 3/, issue.message)
    assert_match(/CLIENTPIDMAP/, issue.message)

    # The property cannot be identified, it stays an independent candidate.
    assert_equal([], result.identified_groups)
    assert_equal(1, result.candidates.size)
  end

  def test_pid_without_source_is_explained
    copy = fields(
      'UID:urn:uuid:contact-1',
      'CLIENTPIDMAP:1;urn:uuid:device-a',
      'EMAIL;PID=4:a@example.com'
    )

    result = Vpim::PropertyIdentity.normalize([ copy ])

    assert_equal([ :pid_without_source ], result.issues.map { |i| i.reason })
    assert_equal(1, result.candidates.size)
  end

  def test_inconsistent_uid_is_explained
    copy_a = fields(
      'UID:urn:uuid:contact-1',
      'CLIENTPIDMAP:1;urn:uuid:device-a',
      'EMAIL;PID=1.1:a@example.com'
    )
    copy_b = fields(
      'UID:urn:uuid:contact-2',
      'CLIENTPIDMAP:1;urn:uuid:device-b',
      'EMAIL;PID=1.1:b@example.com'
    )

    result = Vpim::PropertyIdentity.normalize([ copy_a, copy_b ])

    inconsistent = result.issues.select { |i| i.reason == :inconsistent_uid }
    assert_equal(1, inconsistent.size)
    assert_equal(1, inconsistent.first.copy_index)
    assert_match(/contact-2/, inconsistent.first.message)
    assert_match(/contact-1/, inconsistent.first.message)
  end

  def test_missing_uid_is_explained
    copy = fields(
      'CLIENTPIDMAP:1;urn:uuid:device-a',
      'EMAIL;PID=1.1:a@example.com'
    )

    result = Vpim::PropertyIdentity.normalize([ copy ])

    assert_equal([ :missing_uid ], result.issues.map { |i| i.reason })
  end

  def test_value_mismatch_conflict_is_reported_not_resolved
    copy_a = fields(
      'UID:urn:uuid:contact-1',
      'CLIENTPIDMAP:1;urn:uuid:device-a',
      'CLIENTPIDMAP:2;urn:uuid:device-b',
      'TEL;PID=1.1:+1-555-0100'
    )
    copy_b = fields(
      'UID:urn:uuid:contact-1',
      'CLIENTPIDMAP:1;urn:uuid:device-a',
      'TEL;PID=1.1:+1-555-9999'
    )

    result = Vpim::PropertyIdentity.normalize([ copy_a, copy_b ])

    assert_equal(1, result.identified_groups.size)
    group = result.identified_groups.first
    # Both versions stay in the group, nothing is overridden.
    assert_equal(2, group.members.size)

    assert_equal(1, result.conflicts.size)
    conflict = result.conflicts.first
    assert_equal(:value_mismatch, conflict.kind)
    assert_equal(group, conflict.group)
  end

  def test_duplicate_identity_within_one_copy_is_conflict
    copy = fields(
      'UID:urn:uuid:contact-1',
      'CLIENTPIDMAP:1;urn:uuid:device-a',
      'EMAIL;PID=1.1:a@example.com',
      'EMAIL;PID=1.1:a@example.com'
    )

    result = Vpim::PropertyIdentity.normalize([ copy ])

    assert_equal(1, result.identified_groups.size)
    kinds = result.conflicts.map { |c| c.kind }
    assert(kinds.include?(:duplicate_in_copy))
  end

  def test_structural_fields_are_not_grouped
    copy = fields(
      'UID:urn:uuid:contact-1',
      'CLIENTPIDMAP:1;urn:uuid:device-a',
      'VERSION:4.0',
      'FN:Some One'
    )

    result = Vpim::PropertyIdentity.normalize([ copy ])

    names = result.groups.flat_map { |g| g.members.map { |m| m.field.name } }
    assert_equal([ 'FN' ], names)
  end
end
