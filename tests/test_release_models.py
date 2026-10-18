"""Release archives round-trip without loading model code or touching real data."""
import hashlib
import json
import os
from pathlib import Path
import subprocess

import pytest

from groundkeeper.worker import POLICY_VERSION, WorkerError, verify_package
from scripts.release_models import SOURCES, load_catalog, pack, split_file, verify_assets


def fixture_packages(root):
    for directory, backend in SOURCES.items():
        model = root / directory
        model.mkdir(parents=True)
        data = b'fictional weights for packaging tests'
        (model / 'weights.safetensors').write_bytes(data)
        manifest = {'format_version': 1, 'policy_version': POLICY_VERSION,
                    'model_id': directory + '-fixture', 'backend': backend,
                    'files': {'weights.safetensors': {'bytes': len(data),
                        'sha256': hashlib.sha256(data).hexdigest()}}}
        (model / 'classifier.json').write_text(json.dumps(manifest))


def packaged(tmp_path):
    source, output, catalog = tmp_path / 'source', tmp_path / 'assets', tmp_path / 'models.json'
    fixture_packages(source)
    pack(source, output, catalog, 'models-fixture')
    return source, output, catalog


@pytest.mark.parametrize('size', [1, 16, 17, 33])
def test_split_reconstructs_exact_bytes_at_boundaries(tmp_path, size):
    source = tmp_path / 'example.tar.gz'
    data = bytes(range(size))
    source.write_bytes(data)
    parts = split_file(source, tmp_path, limit=16)
    assert b''.join((tmp_path / p['name']).read_bytes() for p in parts) == data
    assert all(0 < p['bytes'] <= 16 for p in parts)
    assert all(hashlib.sha256((tmp_path / p['name']).read_bytes()).hexdigest() == p['sha256'] for p in parts)


def test_install_round_trip_and_refuse_overwrite(tmp_path):
    source, output, catalog = packaged(tmp_path)
    data = load_catalog(catalog)
    verify_assets(data, output)
    binaries = tmp_path / 'bin'
    binaries.mkdir()
    # Suppress opening Finder during this fictional installation.
    (binaries / 'open').write_text('#!/bin/sh\nexit 0\n')
    (binaries / 'open').chmod(0o755)
    home = tmp_path / 'home with spaces'
    env = dict(os.environ, HOME=str(home), PATH=str(binaries) + os.pathsep + os.environ['PATH'])
    command = ['bash', str(output / 'Install Models.command')]
    subprocess.run(command, env=env, check=True, capture_output=True, timeout=15)
    installed = home / 'Library/Application Support/GroundKeeper/Models/models-fixture'
    for model in data['models']:
        result, digest = verify_package(installed / model['directory'], lambda: False)
        assert digest == model['manifest_sha256']
        assert result['model_id'] == model['model_id']
    result = subprocess.run(command, env=env, capture_output=True, text=True, timeout=15)
    assert result.returncode != 0
    assert 'Destination already exists' in result.stderr


def test_corrupt_asset_rejected_even_at_same_size(tmp_path):
    _, output, catalog = packaged(tmp_path)
    data = load_catalog(catalog)
    part = output / data['models'][0]['parts'][0]['name']
    part.write_bytes(b'x' * part.stat().st_size)
    with pytest.raises(ValueError, match='failed verification'):
        verify_assets(data, output)


@pytest.mark.parametrize('tag', ['..', '../elsewhere', '$(id)', 'bad"tag'])
def test_catalog_rejects_unsafe_install_destination(tmp_path, tag):
    _, _, catalog = packaged(tmp_path)
    data = json.loads(catalog.read_text())
    data['release_tag'] = tag
    catalog.write_text(json.dumps(data))
    with pytest.raises(ValueError, match='release tag'):
        load_catalog(catalog)


def test_catalog_rejects_wrong_part_order_and_paths(tmp_path):
    _, _, catalog = packaged(tmp_path)
    data = json.loads(catalog.read_text())
    for name in ['../outside.tar.gz.part001', 'GroundKeeper-qwen-delaware.tar.gz.part002']:
        data['models'][0]['parts'][0]['name'] = name
        catalog.write_text(json.dumps(data))
        with pytest.raises(ValueError, match='asset name'):
            load_catalog(catalog)


def test_extra_source_files_cannot_be_published(tmp_path):
    source = tmp_path / 'source'
    fixture_packages(source)
    (source / 'qwen-delaware' / 'private-training-data.json').write_text('{}')
    with pytest.raises(WorkerError, match='Unexpected package files'):
        pack(source, tmp_path / 'assets', tmp_path / 'catalog.json', 'models-fixture')
