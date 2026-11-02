import os
import tempfile
import unittest
import wave
from pathlib import Path

from prepare_audio import prepare_wav


class PrepareAudioTests(unittest.TestCase):
    def test_repairs_overstated_pcm_chunk_lengths(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "source.wav"
            destination = Path(directory) / "prepared.wav"
            pcm_data = b"\x01\x00\x02\x00\x03\x00\x04\x00"

            with wave.open(str(source), "wb") as wav_file:
                wav_file.setnchannels(1)
                wav_file.setsampwidth(2)
                wav_file.setframerate(48000)
                wav_file.writeframes(pcm_data)

            with open(source, "r+b") as wav_file:
                wav_file.seek(4)
                riff_size = int.from_bytes(wav_file.read(4), "little")
                wav_file.seek(4)
                wav_file.write((riff_size + 512).to_bytes(4, "little"))
                wav_file.seek(40)
                data_size = int.from_bytes(wav_file.read(4), "little")
                wav_file.seek(40)
                wav_file.write((data_size + 512).to_bytes(4, "little"))

            frame_count = prepare_wav(source, destination)

            self.assertEqual(frame_count, 4)
            with wave.open(str(destination), "rb") as prepared:
                self.assertEqual(prepared.getnframes(), 4)
                self.assertEqual(prepared.readframes(4), pcm_data)

    def test_rejects_non_48khz_or_non_mono_audio(self):
        with tempfile.TemporaryDirectory() as directory:
            source = os.path.join(directory, "source.wav")
            destination = os.path.join(directory, "prepared.wav")
            with wave.open(source, "wb") as wav_file:
                wav_file.setnchannels(2)
                wav_file.setsampwidth(2)
                wav_file.setframerate(48000)
                wav_file.writeframes(b"\x00" * 8)

            with self.assertRaises(ValueError):
                prepare_wav(source, destination)


if __name__ == "__main__":
    unittest.main()
