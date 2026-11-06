# OmniChat per iOS

App di chat IA per iOS (SwiftUI, iOS 17+) con interfaccia nello stile dell'app ChatGPT per iOS. Riprende le funzioni di [aifreeforever.com/chat/gpt-5](https://aifreeforever.com/chat/gpt-5): selettore modelli, ruolo e nome dell'IA, lunghezza e formato delle risposte, lingua, ricerca web, modalità focus, allegati immagine e cronologia delle chat.

## Funzioni

- **Selettore modelli** nel titolo (come ChatGPT): 24 modelli preferiti già pronti (GPT 5, GPT 5.4, Claude Opus 5.5, Gemini 3.5 Flash, DeepSeek V4, Grok 4, Kimi K2.6, Qwen, Llama, GLM e altri), più la scheda **Tutti i modelli**, che scarica la lista aggiornata dal provider. Con la stella aggiungi un modello ai preferiti.
- **Streaming** delle risposte token per token, con pulsante Stop
- **Markdown**: titoli, elenchi, citazioni, tabelle, blocchi di codice con pulsante Copia
- **Menu laterale** con ricerca, chat raggruppate per data, rinomina, condividi ed elimina
- **Tono e formato**: 22 ruoli (Programmatore, Insegnante, Chef…), 11 nomi (Aria, Luna, Kai…), lunghezza (Breve / Bilanciata / Dettagliata), formato (Paragrafi / Elenco / Passo dopo passo / Misto) e 13 lingue
- **Cerca sul web** (OpenRouter `:online`) e **Modalità focus**
- **Allegati foto** per i modelli con visione
- Modifica dei messaggi, rigenerazione, copia, condivisione
- Tema chiaro, scuro o di sistema e feedback aptico
- API key salvata nel Portachiavi; chat salvate solo sul dispositivo

## Backend

Il sito non ha un'API pubblica, quindi l'app usa una qualsiasi **API compatibile con OpenAI**:

| Provider | Base URL |
|---|---|
| **OpenRouter** (consigliato: una sola chiave per centinaia di modelli, inclusi gratuiti) | `https://openrouter.ai/api/v1` |
| OpenAI | `https://api.openai.com/v1` |
| Groq | `https://api.groq.com/openai/v1` |
| Personalizzato (LM Studio, Ollama, LiteLLM…) | il tuo URL |

1. Crea una chiave su <https://openrouter.ai/keys>
2. Apri l'app, poi **Impostazioni**, incolla la chiave e tocca **Verifica connessione**

> Gli ID dei modelli predefiniti sono in `OmniChat/Models/ModelCatalog.swift`. Se un ID dà errore 404, scegli il modello giusto dalla scheda **Tutti i modelli** (lista live) oppure correggi il file.

## Struttura

```
.
├── .github/workflows/build.yml   # CI: XcodeGen + build + IPA non firmato
├── project.yml                   # Specifica XcodeGen
└── OmniChat/
    ├── App/          # Entry point e stato globale
    ├── Models/       # Modelli dati e catalogo modelli IA
    ├── Services/     # Client API (streaming SSE), storage, Keychain
    ├── Views/        # Chat, sidebar, selettore modelli, impostazioni
    └── Resources/    # Assets (icona, colore accento)
```

## Build in locale

```bash
brew install xcodegen
xcodegen generate
open OmniChat.xcodeproj
```

In Xcode seleziona il tuo Team in *Signing & Capabilities* (cambia anche il bundle ID `com.omnichat.app` se serve) e avvia l'app su simulatore o iPhone.

## Build con GitHub Actions

Ogni push su `main` avvia `.github/workflows/build.yml`, che:

1. genera il progetto con XcodeGen
2. compila in Release per `iphoneos` **senza firma**
3. crea `OmniChat-unsigned.ipa` e lo carica tra gli **Artifacts** del workflow

Se pubblichi un tag `v*` (es. `git tag v1.0.0 && git push --tags`), l'IPA viene allegato anche a una **GitHub Release**.

L'IPA non è firmato: per installarlo firmalo con **AltStore**, **SideStore**, **Sideloadly** o con il tuo certificato Apple Developer.

## Note

OmniChat è un client indipendente e non è affiliato con OpenAI, Anthropic, Google, aifreeforever.com o altri fornitori. I nomi dei modelli appartengono ai rispettivi proprietari.
