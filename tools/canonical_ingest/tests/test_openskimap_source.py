import unittest
from canonical_ingest.sources import openskimap


def feature(name, coordinates, **properties):
    return {'properties': dict(name=name, **properties),
            'geometry': {'type': 'LineString', 'coordinates': coordinates}}


class OpenSkiMapSourceTests(unittest.TestCase):
    def test_world_download_is_filtered_to_resort_including_crossing_ways(self):
        nearby = feature('Local', [[-106, 39], [-106.01, 39.01]])
        remote = feature('Other mountain', [[138, 36], [138.01, 36.01]])
        crossing = feature('Crossing', [[-107, 39.05], [-105, 39.05]])
        result = openskimap._filter_bbox({'features': [nearby, remote, crossing]}, (38.9, -106.1, 39.1, -105.9))
        self.assertEqual([f['properties']['name'] for f in result['features']], ['Local', 'Crossing'])

    def test_modern_schema_preserves_way_identity_lift_type_and_filters_inactive(self):
        chair = feature('Chair', [[1, 1], [2, 2]], liftType='chair_lift', status='operating',
                        sources=[{'type': 'openstreetmap', 'id': 'way/123'},
                                 {'type': 'openstreetmap', 'id': 'relation/456'},
                                 {'type': 'skimap.org', 'id': '789'}])
        closed = feature('Removed', [[1, 1], [2, 2]], liftType='chair_lift', status='abandoned')
        items = openskimap._extract_features({'features': [chair, closed]}, kind='lift')
        self.assertEqual(len(items), 1)
        self.assertEqual(items[0].osm_way_ids, ('123',))
        self.assertEqual(items[0].extra['lift_type'], 'chair_lift')

    def test_nordic_routes_and_disconnected_geometry_do_not_become_downhill_routes(self):
        nordic = feature('Nordic', [[1, 1], [2, 2]], uses=['nordic'])
        downhill = feature('Downhill', [[1, 1], [2, 2]], uses=['downhill'])
        self.assertEqual([x.name for x in openskimap._extract_features({'features': [nordic, downhill]}, kind='trail')], ['Downhill'])
        self.assertIsNone(openskimap._coerce_linestring({'type': 'MultiLineString', 'coordinates': [
            [[1, 1], [2, 2]], [[3, 3], [4, 4]],
        ]}))

    def test_invalid_bbox_fails(self):
        for bounds in [(1, 2, 0, 3), (0, 0, float('nan'), 1)]:
            with self.assertRaises(ValueError):
                openskimap._filter_bbox({'features': []}, bounds)
