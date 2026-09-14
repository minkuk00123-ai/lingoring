# API 키 발급 가이드

링고링은 마이크로 말한 내용을 기기에서 whisper.cpp(`whisper_ggml`, 온디바이스, 클라우드 전송 없음)로 텍스트로 바꾸고, NVIDIA의 무료 API(build.nvidia.com, OpenAI 호환, 신용카드 불필요)로 답변을 받은 뒤 기기 내장 TTS(`flutter_tts`)로 읽어줍니다. 서버가 따로 없고, 무료 티어 한도 안에서는 비용도 없습니다.

1. https://build.nvidia.com 에서 로그인 (NVIDIA 계정 또는 소셜 로그인)
2. 아무 모델 페이지에서(예: 검색창에 "llama-3.2-1b" 검색) "Get API Key" 클릭해서 키 발급
3. 발급된 키를 프로젝트 루트의 `.env` 파일에 채워 넣기 (`.env`는 git에 커밋되지 않음)

```
NVIDIA_API_KEY=여기에_붙여넣기
```

키가 비어있으면 대화 화면에 안내 배너가 뜨고 AI 응답을 받을 수 없습니다. 무료 티어는 모델별로 분당 요청 수 제한(대략 40 RPM)이 있습니다. 지금 코드(`lib/core/services/conversation_service.dart`)는 `meta/llama-3.2-11b-vision-instruct` 모델을 씁니다(원래 이미지+텍스트용 VLM이지만 텍스트만 보내도 정상 동작 — 실제 키로 확인함) — 더 빠르게 하려면 `meta/llama-3.2-1b-instruct`(edge용, 품질 낮음)로, 더 자연스럽게 하려면 `meta/llama-3.1-70b-instruct` 같은 대형 모델로 `_model` 값만 바꾸면 됩니다. Gemini와 달리 JSON 출력이 강제되지 않는 모델이라, 코드에서 마크다운 코드펜스(` ```json `)를 벗겨내는 방어 로직을 같이 넣어뒀습니다.

## 보안 참고

지금 구조는 앱(클라이언트)이 `.env`의 키를 직접 들고 API를 호출합니다. 개인 개발/테스트 단계에서는 문제없지만, 앱을 스토어에 배포해 다른 사람이 설치하게 되면 앱 바이너리를 분석해 이 키가 노출될 수 있습니다. 공개 배포 전에는 이 키를 서버(백엔드 프록시)로 옮기고, 앱은 그 서버를 통해서만 호출하도록 구조를 바꾸는 걸 권장합니다.

## 온디바이스 STT (whisper.cpp)

`lib/core/services/whisper_stt_service.dart`가 안드로이드 내장 `SpeechRecognizer`를 완전히 대체합니다. `record` 패키지로 마이크에서 raw PCM16 16kHz를 직접 스트리밍하고, `whisper_ggml`(whisper.cpp FFI 바인딩)로 온디바이스 추론합니다. 첫 실행 시 모델(`WhisperModel.baseEn`, 약 140MB)을 한 번 다운로드해 기기에 캐시하고, 이후로는 인터넷 연결 없이도 동작합니다. 안드로이드 OS가 재생하던 시작/종료 삑삑음, `permanent: true` 오류 플래그 버그, 부분 결과만 잡히고 최종 결과가 안 오던 문제 등은 이 구조에서 원천적으로 발생하지 않습니다(더 이상 시스템 SpeechRecognizer를 거치지 않으므로).

발화 종료 판정은 PCM16 진폭(RMS)이 `voiceRmsThreshold` 아래로 `silenceTimeout`(기본 1.5초) 이상 유지되면 종료하는 방식입니다. 응답이 너무 빨리/늦게 끊긴다면 `WhisperSttService.listenUntilSilence()` 호출부의 `silenceTimeout`/`voiceRmsThreshold` 값을 조정하세요. 속도를 더 올리고 싶다면 `ensureModelReady()`의 `WhisperModel.baseEn`을 더 작고 빠른 `WhisperModel.tinyEn`으로 바꾸는 것도 방법입니다(정확도는 다소 낮아짐).

`whisper_ggml`은 pub.dev 최신(2.6.0)에 `compileSdk` 버그가 있어 `packages/whisper_ggml`에 로컬로 벤더링하고 한 줄(`compileSdk 34` → `36`)만 패치해 사용 중입니다. 패키지가 업데이트되면 이 패치가 필요한지 다시 확인하세요.
