# ML Lifecycle Architecture Audit

> **Status: review of a design-only subsystem.** This audits the ML lifecycle design in `ML_LIFECYCLE_ARCHITECTURE.md`. The Swift `Learning/` cluster it critiques was removed during cleanup as unwired dead code (restore from the cleanup backup before building it out). The critiques remain valid for whoever implements the design.

## 1. EXECUTIVE SUMMARY
- **Is system trainable?** CONDITIONAL
- **Main risks (top 3):** 
  1. Test/Validation set validity is completely destroyed by Active Learning selection bias.
  2. Single-centroid representations fail geometrically for multi-modal text distributions.
  3. Temperature calibration is invalid because it operates on a biased dataset.
- **Expected failure mode:** The system will overfit to edge cases and noisy user complaints, catastrophically forgetting general "easy" samples. It will report high accuracy and low FP rates on its test set, but fail immediately in production because the test set distribution does not match reality.

## 2. CRITICAL ISSUES
- **Evaluation Validity Destroyed by AL Selection Bias:** The chronologically split Test and Validation sets are drawn entirely from the Active Learning queue (which heavily oversamples the $0.35 \leq U \leq 0.75$ uncertainty band and user FP/FNs). Evaluating `fpRate` or `accuracy` on this test set provides zero information about real-world performance. The metrics will be mathematically disconnected from the true production distribution.
- **Temperature Calibration on Shifted Distributions:** Temperature scaling requires a validation set that perfectly matches the target deployment distribution. Because the validation set is sourced from the highly skewed AL queue, applying temperature scaling will miscalibrate the model, likely forcing it to become artificially underconfident or overconfident depending on the band density.
- **Single Centroid Assumption for Multi-Modal Distributions:** Text embeddings for "Human" are fundamentally multi-modal (e.g., conversational vs. institutional). Using a single EMA centroid for a class means the centroid will land in the mathematical center—often empty space between modes. Distance to this void is a geometrically invalid feature that will permanently confuse the classifier.

## 3. HIGH-IMPACT RISKS
- **Noisy Label Contamination of EMA Centroids:** User-submitted FP/FNs are notoriously unreliable. Updating the EMA centroids based on user-validated samples without a gold-standard oracle will introduce dataset poisoning. A biased user can permanently drift the centroids, which breaks the inference distance features and creates a self-reinforcing feedback loop of incorrect predictions.
- **Confident Adversarial Blindspots:** The strict uncertainty band sampling ($0.35 \leq U \leq 0.75$) guarantees that highly confident adversarial text (e.g., AI that perfectly mimics humans, yielding $U < 0.1$) will NEVER be sampled unless a user explicitly reports it. The model will remain completely blind to new, highly successful adversarial attacks.

## 4. STRUCTURAL WEAKNESSES
- **Conflation of Uncertainty Types:** Reducing epistemic, aleatoric, and distributional shift uncertainty into a single scalar (sigmoid distance) prevents the system from distinguishing between "I don't know this text type" (needs sampling) and "This text is fundamentally ambiguous" (should not be sampled).
- **Head-Only Fine-Tuning Limitations:** Because only `[Float]` embeddings are stored and the feature extractor is assumed frozen, the architecture assumes the pre-trained embedding space already linearly separates all future AI mimics from human text. If a new frontier AI model collapses its outputs into the human embedding manifold, head-only/LoRA tuning cannot mathematically separate them.

## 5. POSITIVE VALIDATIONS
- The strict adherence to privacy by not persisting raw text is rigorously enforced via the `[Float]`-only storage design and is ready for privacy-first environments.
- The use of SHA256 `block_hash` deduplication ensures sample purity and prevents over-weighting of repetitive texts.
- The chronological split (Train -> Val -> Test) effectively eliminates temporal leakage (predicting the past using the future), which is critical for tracking adversarial shifts over time.

## 6. FINAL VERDICT
NOT READY

## 7. RECOMMENDED FIXES (PRIORITIZED)
1. **Maintain a True Random Holdout Set (Critical):** Implement a shadow sampling pipeline that randomly selects a small percentage of *all* inference traffic (completely independent of the AL queue) to serve as the gold-standard validation and test set. 
2. **Delay Temperature Calibration (Critical):** Perform calibration *only* on the true random holdout set. Calibrating on the AL-selected data will mathematically ruin the model's probability outputs.
3. **Replace Single Centroids with GMMs or K-NN Anchors (High):** Do not use a single EMA centroid for distance features. Maintain a fixed set of $K$ anchor embeddings per class to accurately capture multi-modal distributions.
4. **Require Oracle Validation for Centroid Updates (High):** Never update EMA centroids based directly on user-reported FP/FNs. Route these to a highly trusted oracle before allowing them to influence the centroid math.
5. **Add True Epistemic Uncertainty (Medium):** Use Monte Carlo Dropout or an ensemble of lightweight heads to measure true epistemic uncertainty, rather than relying on sigmoid distance from the decision boundary.
