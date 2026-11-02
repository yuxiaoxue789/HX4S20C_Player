import argparse
import wave
from pathlib import Path


DEFAULT_MUSIC = Path(r"C:\Users\LX\Downloads\music_48k.wav")
DEFAULT_VOICE = Path(r"C:\Users\LX\Downloads\voice_48k.wav")
DEFAULT_OUTPUT = Path(__file__).resolve().parent / "audio_ready"


def prepare_wav(source, destination):
    with wave.open(str(source), "rb") as input_wav:
        channels = input_wav.getnchannels()
        sample_width = input_wav.getsampwidth()
        sample_rate = input_wav.getframerate()
        if (
            input_wav.getcomptype() != "NONE"
            or channels != 1
            or sample_width != 2
            or sample_rate != 48000
        ):
            raise ValueError(
                f"{source} must be uncompressed mono PCM, 16-bit, 48000 Hz"
            )

        frame_width = channels * sample_width
        pcm_data = input_wav.readframes(input_wav.getnframes())
        pcm_data = pcm_data[:len(pcm_data) - (len(pcm_data) % frame_width)]

    destination = Path(destination)
    destination.parent.mkdir(parents=True, exist_ok=True)
    with wave.open(str(destination), "wb") as output_wav:
        output_wav.setnchannels(1)
        output_wav.setsampwidth(2)
        output_wav.setframerate(48000)
        output_wav.writeframes(pcm_data)
    return len(pcm_data) // frame_width


def main():
    parser = argparse.ArgumentParser(
        description="Validate and prepare the player's 48 kHz mono WAV files."
    )
    parser.add_argument("--music", type=Path, default=DEFAULT_MUSIC)
    parser.add_argument("--voice", type=Path, default=DEFAULT_VOICE)
    parser.add_argument("--output-dir", type=Path, default=DEFAULT_OUTPUT)
    args = parser.parse_args()

    for source, name in (
        (args.music, "music_48k.wav"),
        (args.voice, "voice_48k.wav"),
    ):
        destination = args.output_dir / name
        frames = prepare_wav(source, destination)
        print(f"{destination}: {frames} frames ({frames / 48000:.2f} seconds)")


if __name__ == "__main__":
    main()
