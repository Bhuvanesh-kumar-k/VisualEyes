import base64
import difflib
import json
import os
from pathlib import Path

from fastapi import FastAPI, File, Form, HTTPException, UploadFile
from fastapi.responses import JSONResponse
from openai import OpenAI

# Read API key from environment variable. Do NOT hardcode it.
OPENAI_API_KEY = os.getenv("OPENAI_API_KEY")
if not OPENAI_API_KEY:
  raise RuntimeError("OPENAI_API_KEY environment variable is not set")

client = OpenAI(api_key=OPENAI_API_KEY)
app = FastAPI(title="Visual Backend", version="0.1.0")

VOICE_DB_PATH = Path(__file__).parent / "voice_db.json"


def _load_voice_db() -> dict:
  if VOICE_DB_PATH.exists():
    with VOICE_DB_PATH.open("r", encoding="utf-8") as f:
      return json.load(f)
  return {}


def _save_voice_db(db: dict) -> None:
  with VOICE_DB_PATH.open("w", encoding="utf-8") as f:
    json.dump(db, f, ensure_ascii=False, indent=2)


async def _transcribe_audio(upload: UploadFile) -> str:
  data = await upload.read()
  try:
    transcript = client.audio.transcriptions.create(
      model="whisper-1",
      file=(upload.filename or "audio.m4a", data, upload.content_type or "audio/m4a"),
    )
  except Exception as exc:  # noqa: BLE001
    raise HTTPException(status_code=500, detail=f"Transcription failed: {exc}") from exc
  return transcript.text


@app.post("/audio/transcribe_translate")
async def audio_transcribe_translate(
  audio: UploadFile = File(...),
  target_language: str = Form("en-IN"),
):
  """Transcribe uploaded audio and translate it to the target language code.

  The mobile app sends an audio file recorded from the microphone and a
  BCP-47 language code like "en-IN", "ta-IN", etc.
  """
  text = await _transcribe_audio(audio)

  prompt = (
    "Translate the following text into language with locale code "
    f"{target_language}. Only return the translated text."
  )

  try:
    chat = client.chat.completions.create(
      model="gpt-4o-mini",
      messages=[
        {"role": "system", "content": prompt},
        {"role": "user", "content": text},
      ],
    )
  except Exception as exc:  # noqa: BLE001
    raise HTTPException(status_code=500, detail=f"Translation failed: {exc}") from exc

  translation = chat.choices[0].message.content
  return {"translation": translation}


@app.post("/vision/analyze")
async def vision_analyze(
  image: UploadFile = File(...),
  language: str = Form("en-IN"),
):
  """Analyze a camera frame and return a concise description for a blind user.

  The description should mention surrounding objects, approximate distances,
  floor condition (wet/dry, steps, slopes), obstacles, and if any screen is
  visible, summarize important on-screen text.
  """
  image_bytes = await image.read()
  image_b64 = base64.b64encode(image_bytes).decode("ascii")

  prompt = (
    "You are a real-time assistant for a blind person. "
    f"Respond in language with locale code {language}. "
    "Look at the image and give a very short description (2-4 sentences) "
    "covering:\n"
    "- main objects and their approximate distance and direction,\n"
    "- floor condition (wet/dry, steps, slopes, obstacles),\n"
    "- anything to be careful about (head-level obstacles, narrow spaces),\n"
    "- if a laptop or TV screen is visible, briefly summarize any important text."
  )

  try:
    chat = client.chat.completions.create(
      model="gpt-4o-mini",
      messages=[
        {
          "role": "user",
          "content": [
            {"type": "text", "text": prompt},
            {
              "type": "image_url",
              "image_url": {
                "url": f"data:image/jpeg;base64,{image_b64}",
              },
            },
          ],
        }
      ],
    )
  except Exception as exc:  # noqa: BLE001
    raise HTTPException(status_code=500, detail=f"Vision analysis failed: {exc}") from exc

  description = chat.choices[0].message.content
  return {"description": description}


@app.post("/vision/ocr")
async def vision_ocr(
  image: UploadFile = File(...),
  language: str = Form("en-IN"),
):
  """Extract readable text from a screen or document in the image.

  This uses the same vision model but focuses on text. The mobile app can
  optionally call this separately when it only cares about on-screen text.
  """
  image_bytes = await image.read()
  image_b64 = base64.b64encode(image_bytes).decode("ascii")

  prompt = (
    "You see a photo that may contain a screen or printed text. "
    f"Read all clearly visible text in language with locale code {language}. "
    "Return only the text, in reading order, without extra commentary."
  )

  try:
    chat = client.chat.completions.create(
      model="gpt-4o-mini",
      messages=[
        {
          "role": "user",
          "content": [
            {"type": "text", "text": prompt},
            {
              "type": "image_url",
              "image_url": {
                "url": f"data:image/jpeg;base64,{image_b64}",
              },
            },
          ],
        }
      ],
    )
  except Exception as exc:  # noqa: BLE001
    raise HTTPException(status_code=500, detail=f"OCR failed: {exc}") from exc

  text = chat.choices[0].message.content
  return {"text": text}


@app.post("/voice/enroll")
async def voice_enroll(
  username: str = Form(...),
  language: str = Form("en-IN"),
  audio: UploadFile = File(...),
):
  """Enroll a user's voice using a spoken passphrase.

  NOTE: This is NOT true biometric speaker recognition. It simply stores the
  transcribed phrase for this username and later checks if the user says a
  similar phrase again. For strong security you would integrate Azure Speaker
  Recognition or another dedicated service.
  """
  phrase = await _transcribe_audio(audio)

  db = _load_voice_db()
  db[username] = {"phrase": phrase, "language": language}
  _save_voice_db(db)

  return JSONResponse({"status": "ok", "username": username})


@app.post("/voice/verify")
async def voice_verify(
  username: str = Form(...),
  audio: UploadFile = File(...),
):
  """Verify a user's voice by comparing the spoken phrase text.

  This compares the new transcription with the stored enrollment phrase using
  a simple similarity measure. It is adequate for a demo but not for
  high-security authentication.
  """
  db = _load_voice_db()
  if username not in db:
    raise HTTPException(status_code=404, detail="User not enrolled")

  enrolled_phrase = db[username]["phrase"]
  spoken_phrase = await _transcribe_audio(audio)

  similarity = difflib.SequenceMatcher(
    None,
    enrolled_phrase.lower(),
    spoken_phrase.lower(),
  ).ratio()

  verified = similarity >= 0.6
  return {"verified": verified, "similarity": similarity}


@app.get("/")
async def root() -> dict:
  return {"status": "ok", "message": "Visual backend is running"}
