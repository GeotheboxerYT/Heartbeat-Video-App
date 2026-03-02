# Pulse Point Backend API

## 1) Install dependencies
```bash
cd "/Users/guysmacbookpro/Documents/Heartbeat Video App/Pulse Point/backend/api"
npm install
```

## 2) Configure env
```bash
cp .env.example .env
```
Then edit `.env` with your MySQL credentials.

## 3) Start API
```bash
npm run dev
```

Server default: `http://localhost:3000`

## 4) Health check
```bash
curl http://localhost:3000/health
```

## 4.1) Verify video upload endpoint
```bash
curl -X POST "http://localhost:3000/api/upload/video" \
  -H "x-api-key: replace_me" \
  -F "video=@/absolute/path/to/video.mov"
```

Expected response includes:
- `videoUrl`

## 5) Example: create session with full payload
```bash
curl -X POST http://localhost:3000/api/sessions/full \
  -H "Content-Type: application/json" \
  -H "x-api-key: replace_me" \
  -d '{
    "session": {
      "userId": 1,
      "sessionUuid": "11111111-2222-3333-4444-555555555555",
      "title": "Demo Workout",
      "startedAt": "2026-03-01 10:00:00",
      "endedAt": "2026-03-01 10:10:00",
      "durationSeconds": 600,
      "minBpm": 95,
      "avgBpm": 138,
      "maxBpm": 172,
      "videoUrl": "https://example.com/video.mov"
    },
    "heartRateSamples": [
      {"tSeconds": 0.0, "bpm": 95},
      {"tSeconds": 1.0, "bpm": 97}
    ],
    "prePvt": {
      "phase": "pre",
      "durationSeconds": 60,
      "totalStimuli": 12,
      "correctTaps": 10,
      "incorrectTaps": 1,
      "falseStarts": 1,
      "misses": 1,
      "lapses": 2,
      "meanReactionMs": 320,
      "medianReactionMs": 300,
      "fastestReactionMs": 210,
      "slowestReactionMs": 640,
      "trialPoints": [
        {"trialIndex": 1, "reactionMs": 250},
        {"trialIndex": 2, "reactionMs": 310}
      ]
    },
    "postPvt": {
      "phase": "post",
      "durationSeconds": 60,
      "totalStimuli": 12,
      "correctTaps": 9,
      "incorrectTaps": 2,
      "falseStarts": 2,
      "misses": 2,
      "lapses": 3,
      "meanReactionMs": 390,
      "medianReactionMs": 370,
      "fastestReactionMs": 240,
      "slowestReactionMs": 790,
      "trialPoints": [
        {"trialIndex": 1, "reactionMs": 300},
        {"trialIndex": 2, "reactionMs": 420}
      ]
    }
  }'
```

## API routes
- `GET /health`
- `POST /api/users/register`
- `POST /api/sessions`
- `POST /api/sessions/:sessionId/heart-rate`
- `POST /api/pvt-results`
- `POST /api/sessions/full`
- `GET /api/sessions?userId=...`
- `GET /api/sessions/:sessionId`
- `GET /api/sessions/:sessionId/heart-rate`
- `GET /api/sessions/:sessionId/pvt-comparison`

## Xcode integration note
Your iPhone app should call this API, not MySQL directly.
