
#
# TESTS
#

from unittest import TestCase

from canvas.repository import Repository, RepoSet


class RepoTestCase(TestCase):

    def setUp(self):
        pass

    def test_repo_empty(self):
        r1 = Repository({})

        self.assertEqual(None, r1.name)
        self.assertEqual(None, r1.stub)
        self.assertEqual(None, r1.baseurl)
        self.assertEqual(None, r1.mirrorlist)
        self.assertEqual(None, r1.metalink)
        self.assertEqual(None, r1.enabled)
        self.assertEqual(None, r1.gpgkey)
        self.assertEqual(None, r1.gpgcheck)
        self.assertEqual(None, r1.cost)
        self.assertEqual(None, r1.exclude)
        self.assertEqual(None, r1.priority)
        self.assertEqual(None, r1.meta_expired)

    def test_repo_equality(self):
        r1 = Repository({'s': 'foo'})
        r2 = Repository({'s': 'foo', 'bu': 'foo'})
        r3 = Repository({'s': 'bar', 'bu': 'foo'})
        r4 = Repository({'s': 'bar', 'bu': 'foo1'})
        r5 = Repository({'s': 'baz', 'bu': 'foo1'})

        # stub is the equality check
        self.assertEqual(r1, r2)
        self.assertNotEqual(r2, r3)
        self.assertEqual(r3, r4)
        self.assertNotEqual(r4, r5)

    def test_reposet_equality(self):
        r1 = Repository({'s': 'foo', 'bu': 'x'})
        r2 = Repository({'s': 'foo', 'bu': 'y'})

        l1 = RepoSet()
        l2 = RepoSet()

        l1.add(r1)
        l2.add(r2)
        self.assertEqual(l1, l2)

    def test_reposet_uniqueness(self):
        r1 = Repository({'s': 'foo', 'bu': 'x'})
        r2 = Repository({'s': 'foo', 'bu': 'y'})
        r3 = Repository({'s': 'bar', 'bu': 'x'})

        l1 = RepoSet()

        l1.add(r1)
        self.assertTrue(len(l1) == 1)

        l1.add(r2)
        self.assertTrue(len(l1) == 1)
        self.assertEqual(l1[0].baseurl, 'x')

        l1.add(r3)
        self.assertTrue(len(l1) == 2)

    def test_reposet_difference(self):
        r1 = Repository({'s': 'foo', 'bu': 'x'})
        r2 = Repository({'s': 'bar', 'bu': 'y'})
        r3 = Repository({'s': 'baz'})
        r4 = Repository({'s': 'car'})

        l1 = RepoSet([r1, r2, r3])
        l2 = RepoSet([r2, r3, r4])

        (luniq1, luniq2) = l1.difference(l2)

        self.assertEqual(RepoSet([r1]), luniq1)
        self.assertEqual(RepoSet([r4]), luniq2)


if __name__ == "__main__":
    import unittest
    suite = unittest.TestLoader().loadTestsFromTestCase(RepoTestCase)
    unittest.TextTestRunner().run(suite)