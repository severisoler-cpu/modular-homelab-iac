# 🔬 Deep Research — Motor Autónomo de Investigación Profunda

Stack basado en [GPT-Researcher](https://github.com/assafelovic/gpt-researcher), un agente autónomo diseñado para llevar a cabo investigaciones exhaustivas en la web, sintetizar información de múltiples fuentes fiables y redactar informes estructurados en Markdown con citas bibliográficas.

---

## 🎯 Capacidades Principales
- **Investigación Iterativa:** Desglosa consultas complejas en subtemas, planifica búsquedas paralelas y navega por decenas de fuentes web.
- **Filtrado y Análisis de Relevancia:** Descarga el contenido completo de las páginas, elimina ruido y resume los puntos clave mediante modelos rápidos.
- **Redacción de Dossiers:** Genera informes completos con estructura formal, datos cuantitativos y verificación de hechos (*fact-checking*).
- **Flexibilidad Híbrida:** Compatible tanto con proveedores comerciales en la nube como con modelos locales ejecutados en Ollama.

---

## ⚙️ Modos de Configuración

El archivo `.env` permite alternar entre dos modos de funcionamiento según tus necesidades de privacidad, coste o potencia:

### ☁️ Opción 1: Modelos en la Nube (Cloud)
Recomendado para investigaciones extensas donde se requieran los razonamientos más avanzados o no se disponga de una GPU dedicada potente:

```bash
# Motor de búsqueda (Tavily ofrece búsquedas optimizadas para agentes IA)
RETRIEVER=tavily
TAVILY_API_KEY=tu_tavily_key

# Modelo de investigación y redacción (ejemplo con Gemini vía endpoint OpenAI-compatible)
SMART_LLM=openai:gemini-2.5-flash
FAST_LLM=openai:gemini-2.5-flash
OPENAI_API_KEY=tu_gemini_api_key
OPENAI_BASE_URL=https://generativelanguage.googleapis.com/v1beta/openai
EMBEDDING_PROVIDER=google
GOOGLE_API_KEY=tu_gemini_api_key
```

*Alternativamente, puedes usar directamente `OPENAI_API_KEY` con `gpt-4o` / `gpt-4o-mini` o modelos de Anthropic.*

---

### 🖥️ Opción 2: Modelos 100% Locales (Vía Ollama)
Ideal para entornos que requieren **máxima privacidad** o funcionamiento sin costes por token, delegando la inferencia en un PC o nodo local con GPU:

```bash
# Motor de búsqueda gratuito sin clave API
RETRIEVER=duckduckgo

# Inferencia local en Ollama (ej. DeepSeek-R1 o Llama 3)
SMART_LLM=ollama:deepseek-r1:14b
FAST_LLM=ollama:llama3.2:3b
OLLAMA_BASE_URL=http://192.168.1.50:11434

# Embeddings locales
EMBEDDING_PROVIDER=ollama
OLLAMA_EMBEDDING_MODEL=nomic-embed-text
```

---

## 🚀 Despliegue y Uso

### 1. Iniciar el servicio
```bash
./deploy.sh deep-research
```

### 2. Lanzar una investigación vía API / Webhook
El contenedor expone una API REST en el puerto `8000`:

```bash
curl -X POST http://localhost:8000/research \
     -H "Content-Type: application/json" \
     -d '{
       "task": {
         "query": "Últimos avances en computación cuántica tolerante a fallos",
         "research_type": "deep"
       }
     }'
```

### 3. Salidas generadas
Los informes generados se guardan automáticamente en `./outputs/` en formato Markdown (`.md`), listos para ser consumidos por n8n, asistentes de voz o enviados por Telegram.
