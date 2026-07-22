import test from "node:test"
import assert from "node:assert/strict"
import { WebVttParser } from "../../app/javascript/player/web_vtt_parser.js"

const parser = new WebVttParser()

test("WebVTT parser accepts identifiers, cue settings, and HTML entities", () => {
  const cues = parser.parse(`WEBVTT\n\n42\n00:01.250 --> 00:03.500 align:center\n<i>Hello &amp; goodbye</i>\n`)

  assert.deepEqual(cues, [
    { start: 1.25, end: 3.5, text: "Hello & goodbye" }
  ])
})

test("WebVTT parser offsets relative subtitle windows onto the playback timeline", () => {
  const cues = parser.parse(`WEBVTT\n\n00:00.500 --> 00:02.000\nWindow cue\n`, 120)

  assert.deepEqual(cues, [
    { start: 120.5, end: 122, text: "Window cue" }
  ])
})

test("WebVTT parser rejects malformed and non-positive cues", () => {
  const cues = parser.parse(`WEBVTT\n\n00:03.000 --> 00:02.000\nBackwards\n\nnot timing\nText\n`)

  assert.deepEqual(cues, [])
})
