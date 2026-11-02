import os
import tempfile
import unittest

from PIL import Image

from convert_images_to_bmp import convert_single_file, resize_to_fit


class ResizeToFitTests(unittest.TestCase):
    def test_supported_source_resolutions_fit_hdmi_canvas(self):
        cases = (
            ((640, 480), (640, 480), (0, 0)),
            ((480, 640), (360, 480), (140, 0)),
            ((800, 600), (640, 480), (0, 0)),
            ((320, 240), (640, 480), (0, 0)),
        )

        for source_size, content_size, content_offset in cases:
            with self.subTest(source_size=source_size):
                source = Image.new('RGB', source_size, (255, 0, 0))
                result = resize_to_fit(source)

                self.assertEqual(result.size, (640, 480))
                self.assertEqual(result.getpixel(content_offset), (255, 0, 0))
                self.assertEqual(
                    result.getpixel(
                        (content_offset[0] + content_size[0] - 1,
                         content_offset[1] + content_size[1] - 1)
                    ),
                    (255, 0, 0)
                )

                if content_offset[0] > 0:
                    self.assertEqual(result.getpixel((0, 240)), (0, 0, 0))
                    self.assertEqual(result.getpixel((639, 240)), (0, 0, 0))

    def test_single_file_conversion_writes_fpga_compatible_bmp(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            source_path = os.path.join(temp_dir, 'portrait.png')
            output_path = os.path.join(temp_dir, 'portrait.bmp')
            Image.new('RGB', (480, 640), (255, 0, 0)).save(source_path)

            self.assertTrue(convert_single_file(source_path, output_path))

            with Image.open(output_path) as result:
                self.assertEqual(result.format, 'BMP')
                self.assertEqual(result.mode, 'RGB')
                self.assertEqual(result.size, (640, 480))
                self.assertEqual(result.getpixel((0, 240)), (0, 0, 0))
                self.assertEqual(result.getpixel((140, 0)), (255, 0, 0))


if __name__ == '__main__':
    unittest.main()
