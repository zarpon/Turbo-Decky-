import importlib.util
from pathlib import Path
import shlex
import unittest

spec = importlib.util.spec_from_file_location('grub_config', Path(__file__).resolve().parents[1] / 'lib/grub_config.py')
grub = importlib.util.module_from_spec(spec)
spec.loader.exec_module(grub)

class GrubTests(unittest.TestCase):
    def test_preserves_both_command_lines_and_disables_mitigations(self):
        source = "GRUB_CMDLINE_LINUX = 'quiet root=UUID=deck'\nGRUB_CMDLINE_LINUX_DEFAULT=\"splash zswap.enabled=0 mitigations=auto\"\n"
        result = grub.transform(source, 'zswap')
        self.assertIn('root=UUID=deck', result)
        self.assertIn('splash', result)
        self.assertEqual(result.count('zswap.enabled='), 1)
        self.assertIn('mitigations=off', result)
        self.assertEqual(grub.transform(result, 'zswap'), result)

    def test_duplicate_and_dynamic_assignments_are_rejected(self):
        for source in ['GRUB_CMDLINE_LINUX="quiet"\nGRUB_CMDLINE_LINUX="other"\n', 'GRUB_CMDLINE_LINUX="$CUSTOM"\n']:
            with self.assertRaises(ValueError): grub.transform(source, 'zram')

    def test_quoted_kernel_arguments_remain_tokens(self):
        source = '''GRUB_CMDLINE_LINUX='quiet test="two words"'\n'''
        result = grub.transform(source, 'zram')
        shell_value = shlex.split(result.split('=', 1)[1])[0]
        self.assertIn('test=two words', shlex.split(shell_value))

if __name__ == '__main__': unittest.main()
