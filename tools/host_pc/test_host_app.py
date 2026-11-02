import os
import tempfile
import unittest

from PIL import Image

from host_app import HEIGHT, IMAGE_BYTES, WIDTH, PlayerHostApp


class PrepareImageTests(unittest.TestCase):
    def test_prepares_bottom_up_rgb_frame_with_letterboxing(self):
        image = Image.new("RGB", (2, 2))
        image.putpixel((0, 0), (255, 0, 0))
        image.putpixel((1, 0), (255, 0, 0))
        image.putpixel((0, 1), (0, 0, 255))
        image.putpixel((1, 1), (0, 0, 255))

        with tempfile.TemporaryDirectory() as directory:
            path = os.path.join(directory, "test.png")
            image.save(path)
            frame = PlayerHostApp.prepare_image(path)

        self.assertEqual(len(frame), IMAGE_BYTES)
        first_row = frame[:WIDTH * 3]
        last_row = frame[(HEIGHT - 1) * WIDTH * 3:HEIGHT * WIDTH * 3]
        self.assertEqual(first_row[:3], b"\x00\x00\x00")
        self.assertEqual(last_row[300 * 3:301 * 3], b"\xff\x00\x00")
        self.assertEqual(first_row[300 * 3:301 * 3], b"\x00\x00\xff")


if __name__ == "__main__":
    unittest.main()
