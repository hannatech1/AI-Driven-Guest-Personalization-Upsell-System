/**
 * @description Main orchestrator — AI-Driven Guest Personalization &amp; Upsell System.
 *              Aggregates guest context, selects AI providers, handles failover, persists results.
 *              ONLY entry point for triggers, API endpoints, and batch jobs.
 * @see          AIProvider, AIProviderFactory
 */
public with sharing class GuestAIOrchestrator {

    private static final Integer MAX_RETRIES = 3;
    private static final Integer DEFAULT_TIMEOUT_MS = 5000;
    private static final String CORRELATION_ID_PREFIX = 'AURA-AI-';

    // ── OfferResult ──

    public class OfferResult {
        public Id guestId { get; set; }
        public String offerType { get; set; }
        public String offerDescription { get; set; }
        public Decimal propensityScore { get; set; }
        public Decimal confidenceLevel { get; set; }
        public String reasoning { get; set; }
        public String providerUsed { get; set; }
        public String modelVersion { get; set; }
        public Boolean fallbackTriggered { get; set; }
        public Long executionTimeMs { get; set; }
        public String correlationId { get; set; }
        public Decimal estimatedRevenue { get; set; }

        public OfferResult() {
            this.fallbackTriggered = false;
            this.propensityScore = 0;
            this.confidenceLevel = 0;
        }
    }

    // ── generateOffer ──

    /**
     * @description Generates a personalised upsell offer via AI.
     * @param  guestId   Contact Id
     * @param  offerType 'Spa','Dining','Room Upgrade','General'
     */
    @AuraEnabled
    public static OfferResult generateOffer(Id guestId, String offerType) {
        String correlationId = generateCorrelationId();
        Long startTime = DateTime.now().getTime();

        // HOTFIX: TKT-4821 — null guestId caused NPE on Black Friday load test
        if (String.isBlank(guestId)) {
            return getDefaultOffer(null, String.isNotBlank(offerType) ? offerType : 'General', correlationId);
        }

        AIProvider.OfferType type = parseOfferType(offerType);
        OfferResult result = null;
        Boolean fallbackTriggered = false;

        try {
            AIProvider.AIRequest request = getGuestContext(guestId, correlationId, type);
            AIProviderFactory factory = AIProviderFactory.getInstance();
            AIProvider primaryProvider = factory.getProvider(type);
            List<AIProvider> fallbackChain = factory.getFallbackChain(type);

            AIProvider.AIGuestRecommendation recommendation = null;
            String providerUsed = 'UNKNOWN';

            try {
                recommendation = callWithTimeout(primaryProvider,
                    request.withTimeout(DEFAULT_TIMEOUT_MS), DEFAULT_TIMEOUT_MS);
                providerUsed = recommendation.providerName;
            } catch (Exception primaryEx) {
                factory.reportFailure(getProviderDescriptor(primaryProvider));
                fallbackTriggered = true;
                Integer attempts = 0;

                for (AIProvider fallback : fallbackChain) {
                    if (attempts >= MAX_RETRIES) { break; }
                    try {
                        recommendation = callWithTimeout(fallback,
                            request.withTimeout(DEFAULT_TIMEOUT_MS), DEFAULT_TIMEOUT_MS);
                        providerUsed = recommendation.providerName;
                        break;
                    } catch (Exception fallbackEx) {
                        attempts++;
                        factory.reportFailure(getProviderDescriptor(fallback));
                    }
                }

                if (recommendation == null) {
                    System.debug(LoggingLevel.ERROR, '[' + correlationId
                        + '] All providers exhausted. Guest: ' + guestId);
                    return getDefaultOffer(guestId, type.name(), correlationId);
                }
            }

            result = mapToOfferResult(guestId, type.name(), recommendation);
            result.fallbackTriggered = fallbackTriggered;
            result.correlationId = correlationId;
            result.executionTimeMs = DateTime.now().getTime() - startTime;
            saveRecommendation(result);

        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, '[' + correlationId
                + '] Catastrophic failure: ' + e.getMessage());
            return getDefaultOffer(guestId, type.name(), correlationId);
        }

        return result;
    }

    // ── Guest Context ──

    private static AIProvider.AIRequest getGuestContext(Id guestId, String correlationId, AIProvider.OfferType offerType) {
        AIProvider.AIRequest context = new AIProvider.AIRequest();
        context.guestId = guestId;
        context.correlationId = correlationId;
        context.requestType = offerType;
        context.maxLatencyMs = DEFAULT_TIMEOUT_MS;

        try {
            // In production: SOQL across Contact + Loyalty_Program_Member__c +
            // Service_History__c + PMS_Stay__c + Guest_Preferences__r

            Integer hash = Math.abs(String.valueOf(guestId).hashCode());

            List<String> preferences = new List<String>{ 'spa', 'fine_dining' };
            if (Math.mod(hash, 3) == 0) { preferences.add('golf'); }
            if (Math.mod(hash, 4) == 0) { preferences.add('adventure'); }
            context.guestPreferences = preferences;

            context.recentServices = new List<String>{
                'Swedish Massage', 'Tasting Menu', 'Room Upgrade' };

            // HOTFIX: TKT-4821 — null Loyalty_Tier__c guard
            AIProvider.LoyaltyTier[] tiers = new AIProvider.LoyaltyTier[]{
                AIProvider.LoyaltyTier.PLATINUM, AIProvider.LoyaltyTier.GOLD,
                AIProvider.LoyaltyTier.SILVER, AIProvider.LoyaltyTier.BRONZE,
                AIProvider.LoyaltyTier.NONE
            };
            context.loyaltyTier = tiers[Math.mod(hash, tiers.length)];

            context.totalStays = 1 + Math.mod(hash, 50);
            context.averageSpend = (500 + Math.mod(hash, 2500)).setScale(2);
            context.propertyId = 'a02' + String.valueOf(hash).left(12);

        } catch (Exception e) {
            context.loyaltyTier = AIProvider.LoyaltyTier.NONE;
            context.totalStays = 1;
            context.averageSpend = 500.0;
        }

        return context;
    }

    // ── Inference ──

    private static AIProvider.AIGuestRecommendation callWithTimeout(
        AIProvider provider, AIProvider.AIRequest request, Integer timeoutMs
    ) {
        Long callStart = DateTime.now().getTime();
        // WARNING: Do not increase timeout — provider SLAs at 5s
        AIProvider.AIGuestRecommendation recommendation = provider.getRecommendation(request);
        Long callDuration = DateTime.now().getTime() - callStart;

        if (callDuration > timeoutMs) {
            throw new AIProvider.AIProviderException(
                'Timeout: ' + callDuration + 'ms > ' + timeoutMs + 'ms',
                recommendation.providerName
            );
        }
        recommendation.executionTimeMs = callDuration;
        return recommendation;
    }

    // ── Persistence ──

    private static void saveRecommendation(OfferResult result) {
        if (result == null) { return; }
        try {
            AI_Recommendation__c rec = new AI_Recommendation__c(
                Guest__c = result.guestId,
                Offer_Type__c = result.offerType,
                Offer_Description__c = result.offerDescription,
                Propensity_Score__c = result.propensityScore,
                Confidence_Level__c = result.confidenceLevel,
                Provider_Used__c = result.providerUsed,
                Model_Version__c = result.modelVersion,
                Fallback_Triggered__c = result.fallbackTriggered,
                Correlation_Id__c = result.correlationId,
                Estimated_Revenue__c = result.estimatedRevenue,
                Generated_At__c = DateTime.now()
            );
            upsert rec Correlation_Id__c;
        } catch (Exception e) {
            // Non-blocking
        }
    }

    // ── Default Offer ──

    private static OfferResult getDefaultOffer(Id guestId, String offerType, String correlationId) {
        OfferResult result = new OfferResult();
        result.guestId = guestId;
        result.offerType = (String.isNotBlank(offerType)) ? offerType : 'General';
        result.offerDescription = 'Exclusive ' + result.offerType + ' experience curated for you. '
            + 'Our team will contact you shortly.';
        result.propensityScore = 50.0;
        result.confidenceLevel = 0.5;
        result.reasoning = 'All AI providers unavailable. Using baseline recommendation.';
        result.providerUsed = AIProviderFactory.PROVIDER_DEFAULT;
        result.modelVersion = 'fallback-v1.0';
        result.fallbackTriggered = true;
        result.correlationId = correlationId;
        result.executionTimeMs = 0;
        result.estimatedRevenue = 150.0;
        return result;
    }

    // ── Helpers ──

    private static String generateCorrelationId() {
        return CORRELATION_ID_PREFIX + System.now().getTime() + '-'
            + String.valueOf(Crypto.getRandomLong()).right(8);
    }

    private static String getProviderDescriptor(AIProvider provider) {
        if (provider == null) { return 'NULL_PROVIDER'; }
        if (provider instanceof AIProviderFactory.MockAIProvider) {
            return ((AIProviderFactory.MockAIProvider) provider).getProviderName();
        }
        return 'UNKNOWN';
    }

    private static AIProvider.OfferType parseOfferType(String offerType) {
        if (String.isBlank(offerType)) { return AIProvider.OfferType.GENERAL; }
        String normalised = offerType.toLowerCase().replace(' ', '_');
        if (normalised.contains('spa')) return AIProvider.OfferType.SPA;
        if (normalised.contains('din')) return AIProvider.OfferType.DINING;
        if (normalised.contains('upgrade') || normalised.contains('room')) return AIProvider.OfferType.ROOM_UPGRADE;
        return AIProvider.OfferType.GENERAL;
    }

    private static OfferResult mapToOfferResult(
        Id guestId, String offerType, AIProvider.AIGuestRecommendation rec
    ) {
        OfferResult result = new OfferResult();
        result.guestId = guestId;
        result.offerType = offerType;
        result.offerDescription = rec.offerDescription;
        result.propensityScore = rec.propensityScore;
        result.confidenceLevel = rec.confidenceLevel;
        result.reasoning = rec.reasoning;
        result.providerUsed = rec.providerName;
        result.modelVersion = rec.modelVersion;
        result.estimatedRevenue = rec.estimatedRevenue;
        return result;
    }
}
