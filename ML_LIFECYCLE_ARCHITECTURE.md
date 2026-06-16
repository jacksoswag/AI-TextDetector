# ML Lifecycle Architecture: Pre-Training Refinement & Active Learning

> **Status: design only — not yet wired.** This describes the intended on-device active-learning + dataset pipeline. The Swift `Learning/` implementation cluster (`PrototypeBank`, `SampleSelectionEngine`, `DatasetCompiler`, `TrainingDatasetRecord`, `EvaluationHarness`, `TrainingSignal`) was removed during cleanup as unwired dead code (it had no entry point from the engine). Restore it from the cleanup backup before building this out. The live feedback path today is `FeedbackTrainingPipeline` + `SemanticEventLog`.

This document defines the surgical, pre-training architecture for the ML infrastructure. It strips away unnecessary complexity to prepare for efficient, lightweight fine-tuning (head-only or LoRA) on M3-class hardware, prioritizing high-impact signal capture and deterministic dataset generation.

---

## A. Full System Architecture Diagram

```mermaid
flowchart TD
    %% Real-Time Inference
    subgraph INFERENCE ["1. Inference Pipeline (M3-Optimized)"]
        direction TB
        Input[Raw Text Input] --> Extractor[Feature & Embedding Capture]
        Extractor --> Model[Classifier Model]
        Extractor -. Embeddings .-> Centroid[Prototype Bank]
        Model --> Calibrator[Calibration Baseline]
        Calibrator --> Output[Predicted Probability & Uncertainty]
    end

    %% Active Learning & Holdout
    subgraph DATA_COLLECTION ["2. Data Collection (Active Learning & Holdout)"]
        direction TB
        Capture[Signal Capture System] --> Selection[Sample Selection Engine (Training Pool)]
        Selection -- 70% Band, 20% Tail, 10% Random --> Queue[Human Review Queue]
        Capture --> Holdout[Gold-Standard Holdout Pool (1-5% Random)]
    end

    %% Data Pipeline
    subgraph DATA_PIPELINE ["3. Dataset Compilation & Training Prep"]
        direction TB
        Queue --> Compiler[Dataset Compiler]
        Compiler --> Record[TrainingDatasetRecord]
        Record --> TrainPrep[Training Compatibility Check]
        Holdout --> EvalPool[Evaluation & Calibration Set]
    end

    %% Connections
    Extractor -. Standardized Vectors .-> Capture
    Model -. Logits & Probs .-> Capture
    Centroid -. Distance Vectors .-> Capture
    Output -. Signals .-> Capture
    
    style INFERENCE fill:#0f172a,stroke:#3b82f6,stroke-width:2px,color:#fff
    style DATA_COLLECTION fill:#1e1b4b,stroke:#8b5cf6,stroke-width:2px,color:#fff
    style DATA_PIPELINE fill:#450a0a,stroke:#ef4444,stroke-width:2px,color:#fff
```

---

## B. Core System Refinements

### 1. Raw Text Handling Clarification & Embedding Capture
The inference pipeline must deterministically output and store numerical metadata.
- **Strict Privacy Constraint:** Raw text MUST NOT be persisted in any storage layer, logs, or dataset artifacts. ONLY embedding vectors, feature vectors, logits/probabilities, uncertainty scores, domain tags, and metadata hashes are stored.
> **Note:** This is a persistence constraint, NOT an execution constraint. Raw text MAY exist transiently in memory during feature extraction only.

### 2. Prototype Bank (Lightweight Feature Augmentation)
A minimal distance mechanism added to the extraction layer, replacing single-centroid collapse with a fixed-size anchor bank.
- **Mechanism:** Maintains $K = 3$ to $5$ anchor embeddings per class using strict EMA updates (or reservoir sampling). Updates are strictly from **VALIDATED training samples** only. **NEVER** from the holdout set, and **NEVER** directly from raw user feedback. User feedback must be queued, validated, and placed in the training pool first.
- **Stability Fix:** Updates must be capped per class per time window and limited to top-confidence training samples only, to prevent centroid drift from noisy or ambiguous updates.
- **Distance Feature:** Computes the *minimum distance* to any anchor AND the *mean distance* across anchors.
> **Known Trade-off:** By only using validated records, centroid learning becomes slower and delays adaptation to new distributions (e.g. adversarial drift). This ensures absolute stability at the cost of being conservative.
- **Weighting:** Introduces optional weighting where human-labeled samples > synthetic samples, and high-confidence samples > low-confidence samples.
- **Mitigation (Confirmation-Weight Drift):** To prevent early high-confidence (but incorrect) predictions from permanently reinforcing incorrect centroid structures, the engine applies an "Early Training Bias Clamp" to limit the influence of high-confidence predictions until a threshold is met.
- **Constraint:** No clustering, no k-means, no GMM fitting, no learned clustering, no manifold learning. Must remain O(K) per inference.

### 3. Calibration Baseline
A simple, robust calibration layer implemented AFTER model inference. Uses global or per-domain temperature scaling. It does NOT modify raw model outputs directly, only scales predicted probabilities.
- **Strict Constraint:** Temperature scaling is ONLY trained on the **Gold-Standard Holdout Set**. It must NOT be fitted on the Active Learning dataset or user-selected samples. Calibration must be frozen between training runs and must not adapt during active learning cycles.
- **Stationarity Warning:** Temperature calibration assumes stationarity. Because the system includes synthetic data, adversarial generation, and active learning drift, calibration is VALID ONLY for short training cycles and frozen evaluation snapshots. It MUST NOT be interpreted as long-term probabilistic truth.

### 4. Uncertainty Score Definition Clarification
Standardized `uncertaintyScore` as a composite scalar derived from model entropy OR sigmoid distance from 0.5.
- **Explicit Constraint:** `UncertaintyScore` is NOT decomposed into multiple types at this stage. It is a single operational signal for sampling only.
> **Known Ceiling:** This scalar conflates epistemic uncertainty (model ignorance), aleatoric uncertainty (input ambiguity), and distribution shift. This limits optimal sample selection later, but is accepted for V1 constraints.

---

## C. Pipeline Readiness Checks

### 1. Active Learning Integration (Sample Selection Engine)
Validated configuration for the selection algorithm (used ONLY for the training pool):
- **Uncertainty Band Filtering (70%):** Targets samples strictly within $0.35 \leq U \leq 0.75$.
- **Tail Sampling Stream (20%):** Captures high-confidence adversarial samples (where $U < 0.1$ AND model confidence > 0.9) OR distribution mismatch samples (where there is high embedding distance from ALL prototype anchors, regardless of uncertainty score).
- **Random Sampling ( $\epsilon$ , 10%):** Dedicates 10% ($\epsilon = 0.1$) to random distribution probing.
- **Failure Case Logging:** Mandatory inclusion of all user-indicated False Positives and False Negatives (queued for validation before training pool entry).

### 2. Gold-Standard Holdout Pool (Evaluation & Calibration ONLY)
A secondary pipeline completely independent of the Active Learning selection logic.
- **Sampling:** 1-5% of ALL production inference traffic is randomly sampled.
- **Rolling Window Refresh:** The holdout set MUST be periodically re-sampled over long time windows to prevent staleness under distribution shift. It must remain statistically random but is not static forever.
- **Anti-Leakage Constraint:** Must NEVER be used for training. No feature derived from holdout data can influence PrototypeBank anchors, calibration parameters, sampling heuristics, or threshold tuning. If any coupling exists, the system state is INVALID. It is strictly preserved for final accuracy reporting, FP/FN measurement, and temperature calibration fitting. Must not be influenced by uncertainty, model disagreement, or user feedback filtering.

### 3. Data Pipeline Readiness (Dataset Compiler)
Ensures structural purity for M3 fine-tuning loops:
- **Dataset Generation:** The Active Learning queue provides the Training Pool. The Gold-Standard Holdout Pool provides the final Evaluation/Test sets. Reporting AL-derived accuracy as system performance is strictly forbidden.
- **Deduplication:** Enforced strictly via SHA256 `block_hash`.
- **Privacy:** `TrainingDatasetRecord` enforces zero raw text persistence. All training inputs are numeric-only tensors (`[Float]`).

### 3. Training Compatibility Check
Data formatting guarantees drop-in readiness for lightweight M3 training cycles (<60 mins target):
- Compatible with frozen backbone + trainable head, LoRA adapter fine-tuning, or MLP-on-embeddings approach.

---

## D. Consistency & Final State Validation

All invariants hold across the system:
- All training inputs are numeric-only tensors.
- No raw text appears in DatasetCompiler output.
- All embeddings are fixed-dimensional and deterministic.
- Calibration does not modify raw model logits, only post-processes probabilities.
- Prototype Bank features are computed only from embedding space and updated ONLY from the training pool.
- TrainingDatasetRecord is fully M3-compatible ([Float] arrays only).

---

## E. Evaluation & Success Measurement (Mandatory Tracking)

While lightweight training cycles can execute, success is formally measured post-training using explicit tracking definitions to prevent deployment of regressive models.

**Evaluation Discipline Enforcement:**
- **TRAINING METRICS:** Computed on AL dataset only, used for debugging only, and are NOT comparable across runs.
- **EVALUATION METRICS (TRUTH):** Computed on the Gold-Standard Holdout Set ONLY. This must be the only reported performance metric. Any mixing of data sources invalidates system claims.

The `EvaluationHarness` metrics include:
- **Per-domain accuracy tracking** (e.g., Conversational vs. Institutional).
- **FP/FN tracking per category** (Critical strict focus on limiting FP rate).
- **Institutional-vs-AI Confusion Matrix** (Must strictly monitor the decision boundary separation between Institutional Human prose and AI-generated mimics).
