/**
 * @description Provider factory — AI-Driven Guest Personalization &amp; Upsell System.
 *              Selects providers by request type, health, and priority. Circuit breaker state.
 *              In production: reads AI_Provider_Config__mdt custom metadata.
 * @see          AIProvider, GuestAIOrchestrator
 */
public with sharing class AIProviderFactory {

    public static final String PROVIDER_VERTEX_AI = 'VertexAI_Provider';
    public static final String PROVIDER_OPEN_AI  = 'OpenAI_Provider';
    public static final String PROVIDER_BEDROCK  = 'Bedrock_Provider';
    public static final String PROVIDER_MOCK     = 'MockProvider';
    public static final String PROVIDER_DEFAULT  = 'DEFAULT';

    private static final Integer CIRCUIT_BREAKER_THRESHOLD = 5;
    private static final Integer HEALTH_CHECK_COOLDOWN_SECONDS = 60;

    private Map<String, AIProvider> providerCache;
    private Set<String> failedProviders;
    private Map<String, Integer> failureCounts;
    private DateTime lastHealthCheck;

    // ── Singleton ──

    private static AIProviderFactory instance;

    public static AIProviderFactory getInstance() {
        if (instance == null) { instance = new AIProviderFactory(); }
        return instance;
    }

    private AIProviderFactory() {
        this.providerCache = new Map<String, AIProvider>();
        this.failedProviders = new Set<String>();
        this.failureCounts = new Map<String, Integer>();
        this.lastHealthCheck = DateTime.now();
    }

    // ── Public API ──

    public AIProvider getProvider(AIProvider.OfferType requestType) {
        // In production: SOQL on AI_Provider_Config__mdt ORDER BY Priority__c ASC
        AIProvider selected = selectBestProvider(toCapability(requestType));
        if (selected != null) { return selected; }

        System.debug(LoggingLevel.WARN, 'No providers available. Falling back to MockProvider.');
        return getMockProvider();
    }

    public List<AIProvider> getFallbackChain(AIProvider.OfferType requestType) {
        List<AIProvider> chain = new List<AIProvider>();
        String capability = toCapability(requestType);

        for (String providerName : getProviderNamesByPriority(capability)) {
            if (!failedProviders.contains(providerName)) {
                AIProvider provider = getProviderByName(providerName);
                if (provider != null) { chain.add(provider); }
            }
        }
        chain.add(getMockProvider());
        return chain;
    }

    public void reportFailure(String providerName) {
        if (String.isBlank(providerName)) { return; }

        Integer currentCount = (failureCounts.containsKey(providerName))
            ? failureCounts.get(providerName) + 1 : 1;
        failureCounts.put(providerName, currentCount);

        if (currentCount >= CIRCUIT_BREAKER_THRESHOLD) {
            failedProviders.add(providerName);
            // In production: Platform Event → PagerDuty
            System.debug(LoggingLevel.ERROR, '[CIRCUIT-BREAKER] ' + providerName
                + ' CIRCUIT OPEN (' + currentCount + ' failures).');
        }

        if (lastHealthCheck == null
            || DateTime.now().getTime() - lastHealthCheck.getTime() > HEALTH_CHECK_COOLDOWN_SECONDS * 1000) {
            performHealthCheck();
        }
    }

    public void resetProvider(String providerName) {
        if (String.isBlank(providerName)) { return; }
        failedProviders.remove(providerName);
        failureCounts.remove(providerName);
    }

    // ── Health Check ──

    private void performHealthCheck() {
        lastHealthCheck = DateTime.now();
        for (String providerName : new Set<String>(failedProviders)) {
            try {
                // In production: HttpRequest to /health endpoint
                AIProvider provider = getProviderByName(providerName);
                if (provider != null) { resetProvider(providerName); }
            } catch (Exception e) { }
        }
    }

    // ── Private Helpers ──

    private String toCapability(AIProvider.OfferType requestType) {
        if (requestType == AIProvider.OfferType.SPA) return 'spa_recommendation';
        if (requestType == AIProvider.OfferType.DINING) return 'dining_recommendation';
        if (requestType == AIProvider.OfferType.ROOM_UPGRADE) return 'upsell_recommendation';
        return 'general_recommendation';
    }

    private List<String> getProviderNamesByPriority(String capability) {
        // In production: SOQL ORDER BY Priority__c ASC
        return new List<String>{ PROVIDER_VERTEX_AI, PROVIDER_OPEN_AI, PROVIDER_BEDROCK };
    }

    private AIProvider selectBestProvider(String capability) {
        for (String providerName : getProviderNamesByPriority(capability)) {
            if (!failedProviders.contains(providerName)) {
                AIProvider provider = getProviderByName(providerName);
                if (provider != null) { return provider; }
            }
        }
        return null;
    }

    private AIProvider getProviderByName(String providerName) {
        if (providerCache.containsKey(providerName)) { return providerCache.get(providerName); }
        // In production: Type.forName() from AI_Provider_Config__mdt.Apex_Class__c
        AIProvider provider = new MockAIProvider(providerName);
        providerCache.put(providerName, provider);
        return provider;
    }

    private AIProvider getMockProvider() {
        if (providerCache.containsKey(PROVIDER_MOCK)) { return providerCache.get(PROVIDER_MOCK); }
        AIProvider mock = new MockAIProvider(PROVIDER_MOCK);
        providerCache.put(PROVIDER_MOCK, mock);
        return mock;
    }

    // ── MockAIProvider ──
    // NOTE: Deterministic results. DO NOT use for A/B testing.
    // In production: replaced by OpenAIProvider/BedrockProvider/VertexAIProvider with HTTP callouts.

    public class MockAIProvider implements AIProvider {

        private final String providerName;
        private final String modelVersion;

        public MockAIProvider(String providerName) {
            this.providerName = providerName;
            if (providerName.contains('OpenAI')) {
                this.modelVersion = 'gpt-4-turbo-2024-04-09';
            } else if (providerName.contains('VertexAI')) {
                this.modelVersion = 'gemini-1.5-pro-002';
            } else if (providerName.contains('Bedrock')) {
                this.modelVersion = 'claude-3.5-sonnet-20241022';
            } else {
                this.modelVersion = 'mock-v3.2.0';
            }
        }

        public String getProviderName() { return this.providerName; }

        public AIProvider.AIGuestRecommendation getRecommendation(AIProvider.AIRequest request) {
            Long startTime = DateTime.now().getTime();

            Integer simulatedLatency = 100 + Math.mod(request.guestId.hashCode(), 250);
            // WARNING: Provider SLAs are at 5s. Do not increase timeout.
            if (request.maxLatencyMs != null && simulatedLatency > request.maxLatencyMs) {
                throw new AIProvider.AIProviderException(
                    'Timeout: ' + simulatedLatency + 'ms > ' + request.maxLatencyMs + 'ms',
                    this.providerName
                );
            }

            String selectedOffer = buildOffer(request);
            AIProvider.AIGuestRecommendation rec = new AIProvider.AIGuestRecommendation();
            rec.guestId = request.guestId;
            rec.recommendedOffer = selectedOffer;
            rec.offerDescription = buildDescription(request, selectedOffer);
            rec.propensityScore = calculatePropensity(request);
            rec.confidenceLevel = calculateConfidence(request);
            rec.reasoning = buildReasoning(request);
            rec.providerName = this.providerName;
            rec.modelVersion = this.modelVersion;
            rec.generatedTimestamp = DateTime.now();
            rec.executionTimeMs = DateTime.now().getTime() - startTime;
            rec.estimatedRevenue = calculateRevenue(request, rec.propensityScore);
            rec.riskFlags = evaluateRiskFlags(request, rec.confidenceLevel);
            return rec;
        }

        private String buildOffer(AIProvider.AIRequest request) {
            Integer hash = Math.abs(request.guestId.hashCode());
            AIProvider.OfferType type = request.requestType;

            if (type == AIProvider.OfferType.SPA) {
                List<String> offers = new List<String>{
                    'Couples Swedish Massage — 20% Off',
                    'Deep Tissue Recovery + Hot Stone — 15% Off',
                    'Signature Aromatherapy — 25% Off',
                    'Sunset Rooftop Yoga — Complimentary',
                    'Himalayan Salt Cave Session — 30% Off'
                };
                return offers.get(Math.mod(hash, offers.size()));
            }
            if (type == AIProvider.OfferType.DINING) {
                List<String> offers = new List<String>{
                    'Chef\'s Tasting Menu + Wine Pairing — 15% Off',
                    'Private Rooftop Dinner — Sunset Slot',
                    'Sunday Brunch for Two — Complimentary Mimosas',
                    'Sushi Omakase at Nobu — Priority Reservation'
                };
                return offers.get(Math.mod(hash, offers.size()));
            }
            if (type == AIProvider.OfferType.ROOM_UPGRADE) {
                List<String> offers = new List<String>{
                    'Ocean View Suite Upgrade — $99/night',
                    'Penthouse Upgrade — 40% Off',
                    'Late Checkout 6PM — Complimentary',
                    'Club Level Access — $49/night'
                };
                return offers.get(Math.mod(hash, offers.size()));
            }
            return 'Personalized Experience Package';
        }

        private String buildDescription(AIProvider.AIRequest request, String offer) {
            AIProvider.LoyaltyTier tier = request.loyaltyTier;
            if (tier == null) {
                return 'Exclusive ' + offer + ' — curated from your preferences.';
            }
            return tier.name() + ' member: ' + offer + '. '
                + 'Based on ' + request.totalStays + ' stays.';
        }

        private Decimal calculatePropensity(AIProvider.AIRequest request) {
            Integer hash = Math.abs(request.guestId.hashCode());
            Decimal base = 45.0;
            AIProvider.LoyaltyTier tier = request.loyaltyTier;

            if (tier == AIProvider.LoyaltyTier.PLATINUM) { base += 25.0; }
            else if (tier == AIProvider.LoyaltyTier.GOLD) { base += 18.0; }
            else if (tier == AIProvider.LoyaltyTier.SILVER) { base += 10.0; }

            if (request.totalStays != null && request.totalStays > 10) { base += 10.0; }
            else if (request.totalStays != null && request.totalStays > 5) { base += 5.0; }

            if (request.averageSpend != null && request.averageSpend > 1500) { base += 10.0; }
            else if (request.averageSpend != null && request.averageSpend > 800) { base += 5.0; }

            base += Math.mod(hash, 10);
            return Math.min(base, 98.0);
        }

        private Decimal calculateConfidence(AIProvider.AIRequest request) {
            Decimal base = 0.6;
            if (request.totalStays != null && request.totalStays > 10) { base += 0.2; }
            else if (request.totalStays != null && request.totalStays >= 3) { base += 0.1; }
            if (request.guestPreferences != null && request.guestPreferences.size() > 3) { base += 0.1; }
            if (request.loyaltyTier != null && request.loyaltyTier != AIProvider.LoyaltyTier.NONE) { base += 0.05; }
            return Math.min(base, 1.0);
        }

        private String buildReasoning(AIProvider.AIRequest request) {
            List<String> reasons = new List<String>();
            AIProvider.LoyaltyTier tier = request.loyaltyTier;

            if (tier != null && tier != AIProvider.LoyaltyTier.NONE) {
                reasons.add(tier.name() + ' tier — high upsell receptivity');
            }
            if (request.totalStays != null && request.totalStays > 5) {
                reasons.add('Repeat guest: ' + request.totalStays + ' stays');
            }
            if (request.recentServices != null && !request.recentServices.isEmpty()) {
                reasons.add('Prefers: ' + request.recentServices[0]);
            }
            if (request.averageSpend != null && request.averageSpend > 1000) {
                reasons.add('Premium spend profile');
            }
            reasons.add(this.providerName + ' (' + this.modelVersion + ')');
            return String.join(reasons, '. ') + '.';
        }

        private Decimal calculateRevenue(AIProvider.AIRequest request, Decimal propensity) {
            Decimal baseRevenue = 150.0;
            if (request.requestType == AIProvider.OfferType.ROOM_UPGRADE) { baseRevenue = 450.0; }
            else if (request.requestType == AIProvider.OfferType.DINING) { baseRevenue = 200.0; }
            return (baseRevenue * propensity / 100.0).setScale(2);
        }

        private List<String> evaluateRiskFlags(AIProvider.AIRequest request, Decimal confidence) {
            List<String> flags = new List<String>();
            if (confidence < 0.5) { flags.add('low_confidence'); }
            if (request.totalStays == null || request.totalStays < 2) { flags.add('data_sparse'); }
            if (request.guestPreferences == null || request.guestPreferences.isEmpty()) {
                flags.add('no_preference_data');
            }
            return flags;
        }
    }
}
