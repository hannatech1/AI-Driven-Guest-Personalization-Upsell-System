/**
 * @description AI inference provider contract — AI-Driven Guest Personalization &amp; Upsell System.
 *              Enables Strategy-pattern interchangeability across OpenAI, Bedrock, and Vertex AI.
 * @see          AIProviderFactory, GuestAIOrchestrator
 */
public interface AIProvider {

    Integer DEFAULT_TIMEOUT_MS = 5000;

    AIProvider.AIGuestRecommendation getRecommendation(AIProvider.AIRequest request);

    enum OfferType { SPA, DINING, ROOM_UPGRADE, GENERAL }
    enum LoyaltyTier { PLATINUM, GOLD, SILVER, BRONZE, NONE }

    class AIRequest {
        public String guestId { get; set; }
        public List<String> guestPreferences { get; set; }
        public List<String> recentServices { get; set; }
        public LoyaltyTier loyaltyTier { get; set; }
        public Integer totalStays { get; set; }
        public Decimal averageSpend { get; set; }
        public String propertyId { get; set; }
        public OfferType requestType { get; set; }
        public String correlationId { get; set; }
        public Integer maxLatencyMs { get; set; }

        public AIRequest withTimeout(Integer timeoutMs) {
            AIRequest clone = new AIRequest();
            clone.guestId = this.guestId;
            clone.guestPreferences = (this.guestPreferences != null)
                ? new List<String>(this.guestPreferences) : null;
            clone.recentServices = (this.recentServices != null)
                ? new List<String>(this.recentServices) : null;
            clone.loyaltyTier = this.loyaltyTier;
            clone.totalStays = this.totalStays;
            clone.averageSpend = this.averageSpend;
            clone.propertyId = this.propertyId;
            clone.requestType = this.requestType;
            clone.correlationId = this.correlationId;
            clone.maxLatencyMs = timeoutMs;
            return clone;
        }
    }

    class AIGuestRecommendation {
        public String guestId { get; set; }
        public String recommendedOffer { get; set; }
        public String offerDescription { get; set; }
        public Decimal propensityScore { get; set; }
        public Decimal confidenceLevel { get; set; }
        public String reasoning { get; set; }
        public String providerName { get; set; }
        public String modelVersion { get; set; }
        public DateTime generatedTimestamp { get; set; }
        public Long executionTimeMs { get; set; }
        public Decimal estimatedRevenue { get; set; }
        public List<String> riskFlags { get; set; }

        public AIGuestRecommendation() {
            this.riskFlags = new List<String>();
        }
    }

    class AIProviderException extends Exception {
        public String providerName { get; private set; }

        public AIProviderException(String message, String providerName) {
            this.setMessage(message);
            this.providerName = providerName;
        }
    }
}
