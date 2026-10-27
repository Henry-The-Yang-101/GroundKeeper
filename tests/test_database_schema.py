"""Installed-schema checks using the app's migrations and fictional SQLite data."""
import json
import sqlite3

import pytest


from scripts.database_schema import apply_migrations


@pytest.fixture
def db():
    connection = sqlite3.connect(':memory:')
    apply_migrations(connection)
    put(connection, 'sources', id='wallet', kind='apple_wallet', name='Test wallet', created_at_ms=0)
    put(connection, 'sources', id='bank', kind='bank_notification', name='Test bank', created_at_ms=0)
    put(connection, 'accounts', id='card', name='Test card', kind='credit_card', currency='CAD', created_at_ms=0)
    yield connection
    assert connection.execute('PRAGMA foreign_key_check').fetchall() == []
    assert connection.execute('PRAGMA integrity_check').fetchone() == ('ok',)
    connection.close()


def put(db, table, **values):
    columns = ','.join(values)
    placeholders = ','.join('?' for _ in values)
    db.execute(f'INSERT INTO {table} ({columns}) VALUES ({placeholders})', tuple(values.values()))


def transaction(db, key='t1', amount=-1250, category='dining', kind='expense', origin='user', **overrides):
    values = dict(id=key, account_id='card', description='Fictional cafe', amount_minor=amount,
                  currency='CAD', occurred_on='2026-10-17', time_precision='date',
                  lifecycle='posted', created_at_ms=0, updated_at_ms=0)
    values.update(overrides)
    put(db, 'transactions', **values)
    put(db, 'transaction_parts', id=key+'p', transaction_id=key, position=0, amount_minor=amount)
    assignment(db, key+'a', key+'p', category=category, kind=kind, origin=origin)
    db.execute('UPDATE transaction_parts SET current_assignment_id=? WHERE id=?', (key+'a', key+'p'))
    db.execute("UPDATE transactions SET state='active' WHERE id=?", (key,))


def assignment(db, key, part, category='dining', kind='expense', origin='user', **overrides):
    values = dict(id=key, part_id=part, type_code=kind, category_id=category, origin=origin,
                  needs_review=int(kind == 'unknown' or (kind in ('expense','refund') and category is None)),
                  selected_at_ms=0)
    if origin == 'user':
        values.update(confirmed_at_ms=0, confirmed_by='local_user')
    values.update(overrides)
    put(db, 'category_assignments', **values)


def event(db, key, source='wallet', source_event_id=None):
    put(db, 'raw_events', id=key, source_id=source, source_event_id=source_event_id or key,
        schema_version=1, event_kind='transaction', captured_at_ms=1000,
        captured_offset_minutes=-240, received_at_ms=2000, payload_sha256='fictional-equal-hash')
    put(db, 'event_observations', id=key+'o', event_id=key, parser_version='test-v1',
        parsed_at_ms=2000, status='parsed', amount_minor=-1250, currency='CAD')


def link(db, key, event_id, transaction_id):
    put(db, 'reconciliation_decisions', id=key+'d', event_id=event_id,
        left_transaction_id=transaction_id, action='link', actor='system', evidence_json='{}', created_at_ms=0)
    put(db, 'transaction_event_links', id=key, event_id=event_id, transaction_id=transaction_id,
        observation_id=event_id+'o', role='capture', decision_id=key+'d', linked_at_ms=0)


def setup_models(db):
    put(db, 'policy_versions', id='policy', name='test', content_sha256='test', definition_json='{}', created_at_ms=0)
    put(db, 'model_versions', id='qwen', provider='local_mlx', model_name='Qwen test', execution='local',
        configuration_json='{}', created_at_ms=0)
    put(db, 'council_configs', id='council', policy_version_id='policy', algorithm_version='test',
        configuration_json='{}', created_at_ms=0)
    put(db, 'council_config_members', config_id='council', model_version_id='qwen', weight=1.0)


def model_run(db, key='r1', part='t1p', kind='model', **overrides):
    values = dict(id=key, part_id=part, input_revision=1, kind=kind, policy_version_id='policy',
                  input_json='{}', input_sha256='test', started_at_ms=0, finished_at_ms=1,
                  status='succeeded', type_code='expense', category_id='dining', needs_review=1)
    values.update(model_version_id='qwen') if kind == 'model' else values.update(council_config_id='council')
    values.update(overrides)
    put(db, 'classification_runs', **values)


def test_foreign_keys_and_seed_categories(db):
    assert db.execute('PRAGMA foreign_keys').fetchone() == (1,)
    assert db.execute('SELECT kind,count(*) FROM categories GROUP BY kind').fetchall() == [
        ('other', 1), ('spending', 18)]
    with pytest.raises(sqlite3.IntegrityError):
        transaction(db, account_id='nonexistent')


def test_duplicate_delivery_identity_and_equal_content_distinct_capture(db):
    event(db, 'e1')
    with pytest.raises(sqlite3.IntegrityError):
        event(db, 'replay', source_event_id='e1')
    event(db, 'e2')  # Same text/hash/time is allowed for a distinct capture.
    assert db.execute('SELECT count(*) FROM raw_events').fetchone() == (2,)


def test_wallet_and_bank_count_once_and_repeat_purchase_counts_separately(db):
    transaction(db)
    event(db, 'w1')
    event(db, 'b1', 'bank')
    link(db, 'lw', 'w1', 't1')
    link(db, 'lb', 'b1', 't1')
    assert db.execute('SELECT sum(net_spending_minor) FROM spending_entries').fetchone() == (1250,)
    assert db.execute('SELECT count(*) FROM transaction_source_summary').fetchone() == (2,)
    transaction(db, 't2')
    event(db, 'w2')
    link(db, 'lw2', 'w2', 't2')
    assert db.execute('SELECT sum(net_spending_minor) FROM spending_entries').fetchone() == (2500,)


def test_event_can_only_have_one_active_transaction_and_relink_retains_history(db):
    transaction(db)
    transaction(db, 't2')
    event(db, 'w1')
    link(db, 'l1', 'w1', 't1')
    with pytest.raises(sqlite3.IntegrityError):
        link(db, 'l2', 'w1', 't2')
    db.execute('UPDATE transaction_event_links SET unlinked_at_ms=1 WHERE id=?', ('l1',))
    link(db, 'l3', 'w1', 't2')
    assert db.execute('SELECT count(*) FROM transaction_event_links').fetchone() == (2,)


def test_observation_cannot_be_attributed_to_another_event(db):
    transaction(db)
    event(db, 'w1')
    event(db, 'w2')
    link(db, 'l1', 'w1', 't1')
    with pytest.raises(sqlite3.IntegrityError):
        db.execute("UPDATE transaction_event_links SET observation_id='w2o' WHERE id='l1'")


def test_split_totals_and_active_amount_guards(db):
    transaction(db)
    with pytest.raises(sqlite3.IntegrityError):
        db.execute("UPDATE transaction_parts SET amount_minor=-100 WHERE id='t1p'")
    with pytest.raises(sqlite3.IntegrityError):
        db.execute("UPDATE transactions SET amount_minor=-100 WHERE id='t1'")
    db.execute("UPDATE transactions SET state='draft' WHERE id='t1'")
    db.execute("UPDATE transaction_parts SET amount_minor=-1000 WHERE id='t1p'")
    with pytest.raises(sqlite3.IntegrityError):
        db.execute("UPDATE transactions SET state='active' WHERE id='t1'")
    put(db, 'transaction_parts', id='split', transaction_id='t1', position=1, amount_minor=-250)
    assignment(db, 'split-a', 'split', category='groceries')
    db.execute("UPDATE transaction_parts SET current_assignment_id='split-a' WHERE id='split'")
    db.execute("UPDATE transactions SET state='active' WHERE id='t1'")
    assert db.execute('SELECT sum(net_spending_minor) FROM spending_entries').fetchone() == (1250,)


def test_money_rejects_fractional_minor_units(db):
    with pytest.raises(sqlite3.IntegrityError):
        transaction(db, amount=-12.5)


def test_expanding_categories_and_cycle_guard(db):
    put(db, 'categories', id='coffee-uuid', code='coffee', name='Coffee', parent_id='dining', created_at_ms=0)
    transaction(db, category='coffee-uuid')
    with pytest.raises(sqlite3.IntegrityError):
        db.execute("UPDATE categories SET parent_id='coffee-uuid' WHERE id='dining'")
    db.execute("UPDATE categories SET name='Coffee shops', archived_at_ms=1 WHERE id='coffee-uuid'")
    assert db.execute('SELECT category_id FROM spending_entries').fetchone() == ('coffee-uuid',)


@pytest.mark.parametrize('kind,category,review', [('income','dining',0), ('expense',None,0),
                                               ('unknown','dining',0), ('expense','uncategorized',0),
                                               ('refund',None,0)])
def test_type_category_and_review_rules(db, kind, category, review):
    transaction(db)
    with pytest.raises(sqlite3.IntegrityError):
        assignment(db, 'bad', 't1p', category=category, kind=kind, needs_review=review)


def test_refunds_reduce_spending_and_transfers_do_not_count(db):
    transaction(db)
    transaction(db, 'refund', amount=250, kind='refund')
    transaction(db, 'transfer', amount=2000, kind='transfer', category=None)
    assert db.execute('SELECT sum(net_spending_minor) FROM spending_entries').fetchone() == (1000,)


def test_retired_pending_status_is_rejected_on_insert_and_update(db):
    with pytest.raises(sqlite3.IntegrityError, match='recorded immediately'):
        transaction(db, 'pending', lifecycle='pending')
    transaction(db)
    with pytest.raises(sqlite3.IntegrityError, match='recorded immediately'):
        db.execute("UPDATE transactions SET lifecycle='pending' WHERE id='t1'")


def test_same_part_assignment_and_append_only_history(db):
    transaction(db)
    transaction(db, 't2')
    with pytest.raises(sqlite3.IntegrityError):
        db.execute("UPDATE category_assignments SET category_id='groceries' WHERE id='t1a'")
    # Commit before checking an initially-deferred owner FK.
    db.commit()
    db.execute("UPDATE transaction_parts SET current_assignment_id='t2a' WHERE id='t1p'")
    with pytest.raises(sqlite3.IntegrityError):
        db.commit()
    db.rollback()


def test_ai_provenance_user_confirmation_and_protection(db):
    transaction(db, origin='system')
    setup_models(db)
    model_run(db)
    assignment(db, 'ai', 't1p', origin='model', run_id='r1', needs_review=1)
    with pytest.raises(sqlite3.IntegrityError):
        assignment(db, 'hide-review', 't1p', origin='model', run_id='r1', needs_review=0)
    db.execute("UPDATE transaction_parts SET current_assignment_id='ai' WHERE id='t1p'")
    assignment(db, 'accept', 't1p', supersedes_id='ai')
    db.execute("UPDATE transaction_parts SET current_assignment_id='accept' WHERE id='t1p'")
    with pytest.raises(sqlite3.IntegrityError):
        db.execute("UPDATE transaction_parts SET current_assignment_id='ai' WHERE id='t1p'")
    assert db.execute("SELECT run_id FROM category_assignments WHERE id='ai'").fetchone() == ('r1',)


@pytest.mark.parametrize('overrides', [dict(category='groceries'), dict(part='t2p'), dict(origin='council')])
def test_misattributed_model_result_rejected(db, overrides):
    transaction(db)
    transaction(db, 't2')
    setup_models(db)
    model_run(db)
    values = dict(category='dining', origin='model', run_id='r1')
    part = overrides.pop('part', 't1p')
    values.update(overrides)
    with pytest.raises(sqlite3.IntegrityError):
        assignment(db, 'bad', part, **values)


def test_council_records_configured_members_and_failures(db):
    transaction(db)
    setup_models(db)
    model_run(db, 'c', kind='council')
    model_run(db, 'm')
    put(db, 'council_votes', council_run_id='c', model_version_id='qwen', member_run_id='m', weight=1.0, disposition='valid')
    assignment(db, 'ca', 't1p', origin='council', run_id='c', needs_review=1)
    with pytest.raises(sqlite3.IntegrityError):
        put(db, 'council_votes', council_run_id='m', model_version_id='qwen', weight=1.0, disposition='skipped')
    model_run(db, 'c2', kind='council')
    put(db, 'council_votes', council_run_id='c2', model_version_id='qwen', weight=1.0, disposition='unavailable')


def test_geotag_optional_bounded_and_source_owned(db):
    transaction(db)
    transaction(db, 't2')
    assert db.execute("SELECT selected_geotag_id FROM transactions WHERE id='t1'").fetchone() == (None,)
    event(db, 'w1')
    put(db, 'geotags', id='geo', event_id='w1', latitude=43.47, longitude=-80.54,
        horizontal_accuracy_m=25, measured_at_ms=1000, origin='phone_capture', created_at_ms=2000)
    with pytest.raises(sqlite3.IntegrityError):
        db.execute("UPDATE transactions SET selected_geotag_id='geo' WHERE id='t1'")
    link(db, 'l1', 'w1', 't1')
    db.execute("UPDATE transactions SET selected_geotag_id='geo' WHERE id='t1'")
    with pytest.raises(sqlite3.IntegrityError):
        db.execute("UPDATE transactions SET selected_geotag_id='geo' WHERE id='t2'")
    with pytest.raises(sqlite3.IntegrityError):
        put(db, 'geotags', id='bad', transaction_id='t1', latitude=100, longitude=0,
            measured_at_ms=1000, origin='user_pin', created_at_ms=2000)


def test_date_only_does_not_fabricate_instant(db):
    transaction(db)
    assert db.execute('SELECT occurred_at_ms,time_precision FROM transactions').fetchone() == (None,'date')
    with pytest.raises(sqlite3.IntegrityError):
        transaction(db, 'bad', time_precision='instant')


def test_category_confirmation_does_not_resolve_other_review_reasons(db):
    transaction(db)
    put(db, 'review_items', id='review', transaction_id='t1', reason_code='possible_duplicate',
        status='open', details_json='{}', created_at_ms=0)
    assert db.execute('SELECT confirmed_at_ms,needs_review,has_open_review FROM current_transaction_parts').fetchone() == (0,0,1)


def test_import_identity_scoped_to_account_and_history_survives_undo(db):
    for key in ('batch1','batch2'):
        values = dict(id=key, source_id='bank', account_scope_id='card', file_sha256='same',
                      original_filename=key+'.csv', mapping_snapshot_json='{}', status='preview', created_at_ms=0)
        if key == 'batch1':
            put(db, 'import_batches', **values)
        else:
            with pytest.raises(sqlite3.IntegrityError):
                put(db, 'import_batches', **values)
    transaction(db)
    event(db, 'csv1', 'bank')
    event(db, 'wallet1')
    link(db, 'lcsv', 'csv1', 't1')
    link(db, 'lw', 'wallet1', 't1')
    put(db, 'import_rows', id='row1', batch_id='batch1', row_number=1, event_id='csv1', status='accepted')
    db.execute("UPDATE import_batches SET status='undone',undone_at_ms=1 WHERE id='batch1'")
    db.execute("UPDATE import_rows SET status='undone' WHERE id='row1'")
    db.execute("UPDATE transaction_event_links SET unlinked_at_ms=1 WHERE id='lcsv'")
    assert db.execute('SELECT sum(net_spending_minor) FROM spending_entries').fetchone() == (1250,)
    assert db.execute('SELECT kind FROM transaction_source_summary').fetchall() == [('apple_wallet',)]


def test_external_record_identity_is_scoped_and_unique(db):
    transaction(db)
    transaction(db, 't2')
    event(db, 'bank1', 'bank')
    values = dict(source_id='bank', external_account_key='fictional-account', namespace='posted',
                  external_record_id='record-1', first_event_id='bank1')
    put(db, 'external_transaction_refs', id='ref1', transaction_id='t1', **values)
    with pytest.raises(sqlite3.IntegrityError):
        put(db, 'external_transaction_refs', id='ref2', transaction_id='t2', **values)
    values['external_account_key'] = 'another-fictional-account'
    put(db, 'external_transaction_refs', id='ref3', transaction_id='t2', **values)


def test_multi_account_csv_batch_replay_is_unique_even_with_null_account(db):
    values = dict(source_id='bank', account_scope_id=None, file_sha256='multi-account-file',
                  original_filename='fictional.csv', mapping_snapshot_json='{}', status='preview', created_at_ms=0)
    put(db, 'import_batches', id='multi1', **values)
    with pytest.raises(sqlite3.IntegrityError):
        put(db, 'import_batches', id='multi2', **values)


def test_transaction_and_part_amounts_retain_account_currency_and_original_fx(db):
    transaction(db, amount=-1700, original_amount_minor=-1250, original_currency='USD')
    assert db.execute('SELECT currency,amount_minor,original_currency,original_amount_minor FROM transactions').fetchone() == (
        'CAD', -1700, 'USD', -1250)
    assert db.execute('SELECT currency,net_spending_minor FROM spending_entries').fetchone() == ('CAD',1700)
    with pytest.raises(sqlite3.IntegrityError):
        transaction(db, 'bad-fx', original_amount_minor=-100)


@pytest.mark.parametrize('source,payload,expected', [
    ('wallet', dict(source='wallet_transaction', app='Wallet', input_shape='wallet_transaction_fields',
                    transaction='Sample tap, not a unique ID', card_or_pass='Sample Visa',
                    merchant='Sample Cafe', amount='CAD 1.23', name='Sample payment'),
     ('wallet_transaction','wallet_transaction_fields','Sample Visa','Sample Cafe','CAD 1.23',
      'Sample payment','Sample tap, not a unique ID',None,None,None)),
    ('bank', dict(source='bank_notification', app='Sample Bank', input_shape='notification_fields',
                  title='Sample card', subtitle='', body='$1.23 — "sample"\nsecond line'),
     ('bank_notification','notification_fields',None,None,None,None,None,
      'Sample card','','$1.23 — "sample"\nsecond line')),
])
def test_v2_capture_shapes_are_preserved_once_and_exposed_in_view(db, source, payload, expected):
    # Fictional version-2 envelope; no production importer or live Shortcut is run.
    payload.update(schema_version=2, event_id='a'*64, captured_at='2026-10-17T15:42:10.000-04:00')
    put(db, 'raw_events', id='capture', source_id=source, source_event_id=payload['event_id'],
        schema_version=2, event_kind='transaction', captured_at_ms=1000,
        captured_offset_minutes=-240, received_at_ms=2000, payload_sha256='fixture')
    encoded = json.dumps(payload, ensure_ascii=False)
    put(db, 'raw_event_payloads', event_id='capture', payload_json=encoded)
    row = db.execute('''SELECT payload_source,input_shape,wallet_card_or_pass_text,wallet_merchant_text,
        wallet_amount_text,wallet_name,wallet_transaction_text,notification_title,notification_subtitle,
        notification_body FROM capture_event_details WHERE event_id='capture' ''').fetchone()
    assert row == expected
    assert db.execute('SELECT payload_json FROM raw_event_payloads').fetchone() == (encoded,)
    assert db.execute('SELECT source_kind FROM capture_event_details').fetchone() == (
        'apple_wallet' if source == 'wallet' else 'bank_notification',)


def test_unknown_card_label_survives_until_mapping_and_sources_share_instrument(db):
    event(db, 'wallet-label')
    event(db, 'bank-label', 'bank')
    db.execute("UPDATE event_observations SET instrument_text='Example Visa' WHERE id='wallet-labelo'")
    assert db.execute("SELECT instrument_text,instrument_id FROM event_observations WHERE id='wallet-labelo'").fetchone() == (
        'Example Visa', None)
    put(db, 'payment_instruments', id='instrument', account_id='card', name='Example Visa', kind='wallet_card')
    db.execute("UPDATE event_observations SET instrument_id='instrument',account_id='card' WHERE id='wallet-labelo'")
    db.execute("UPDATE event_observations SET instrument_text='Example card, bank label',instrument_id='instrument',account_id='card' WHERE id='bank-labelo'")
    transaction(db, instrument_id='instrument')
    link(db, 'wallet-link', 'wallet-label', 't1')
    link(db, 'bank-link', 'bank-label', 't1')
    assert db.execute('SELECT sum(net_spending_minor) FROM spending_entries').fetchone() == (1250,)
    assert db.execute('SELECT last_four FROM payment_instruments').fetchone() == (None,)


def test_test_capture_cannot_be_linked_or_swapped_into_transaction_evidence(db):
    transaction(db)
    event(db, 'sample')
    db.execute("UPDATE raw_events SET is_test=1 WHERE id='sample'")
    with pytest.raises(sqlite3.IntegrityError, match='test captures'):
        link(db, 'test-link', 'sample', 't1')
    event(db, 'real')
    link(db, 'real-link', 'real', 't1')
    with pytest.raises(sqlite3.IntegrityError, match='test captures'):
        db.execute("UPDATE transaction_event_links SET event_id='sample',observation_id='sampleo' WHERE id='real-link'")


def test_capture_view_preserves_event_when_payload_expires_or_old_fields_missing(db):
    event(db, 'old')
    put(db, 'raw_event_payloads', event_id='old', payload_json='{"source":"bank_notification","input_shape":"separate_fields"}')
    assert db.execute("SELECT wallet_card_or_pass_text,notification_body,is_test FROM capture_event_details WHERE event_id='old'").fetchone() == (None,None,0)
    db.execute("DELETE FROM raw_event_payloads WHERE event_id='old'")
    assert db.execute("SELECT input_shape,wallet_card_or_pass_text FROM capture_event_details WHERE event_id='old'").fetchone() == (None,None)
