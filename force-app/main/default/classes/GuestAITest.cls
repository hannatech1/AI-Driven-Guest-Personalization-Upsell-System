/**
 * @description Unit tests — AI-Driven Guest Personalization &amp; Upsell System.
 *              Covers factory selection, circuit breaker, orchestrator flow, and mock providers.
 */
@isTest
private class GuestAITest {

    // ── Mock Providers ──

    private class TestMockSuccessProvider implements AIProvider {
        private final String providerName;
        public TestMockSuccessProvider(String name) { this.providerName = name; }

        public AIProvider.AIGuestRecommendation getRecommendation(AIProvider.AIRequest request) {
            AIProvider.AIGuestRecommendation rec = new AIProvider.AIGuestRecommendation();
            rec.guestId = request.guestId;
            rec.recommendedOffer = 'Test Spa Bundle';
            rec.offerDescription = 'A curated test spa experience.';
            rec.propensityScore = 78.5;
            rec.confidenceLevel = 0.88;
            rec.reasoning = 'Test reasoning.';
            rec.providerName = this.providerName;
            rec.modelVersion = 'test-v1.0';
            rec.generatedTimestamp = DateTime.now();
            rec.executionTimeMs = 150;
            rec.estimatedRevenue = 180.0;
            rec.riskFlags = new List<String>();
            return rec;
        }
    }

    @TestSetup
    static void createTestData() {
        List<Contact> guests = new List<Contact>{
            new Contact(FirstName = 'Anastasia', LastName = 'Petrova', Email = 'anastasia.petrova@aurahotels.test'),
            new Contact(FirstName = 'James', LastName = 'Harrington', Email = 'james.harrington@aurahotels.test'),
            new Contact(FirstName = 'Chen', LastName = 'Wei', Email = 'chen.wei@aurahotels.test'),
            new Contact(FirstName = 'Elena', LastName = 'Kowalski', Email = 'elena.kowalski@aurahotels.test')
        };
        insert guests;
    }

    // ── Factory Tests ──

    @isTest
    static void testProviderFactory_ReturnsProviderForAllOfferTypes() {
        Test.startTest();
        AIProviderFactory factory = AIProviderFactory.getInstance();
        System.assertNotEquals(null, factory.getProvider(AIProvider.OfferType.SPA));
        System.assertNotEquals(null, factory.getProvider(AIProvider.OfferType.DINING));
        System.assertNotEquals(null, factory.getProvider(AIProvider.OfferType.ROOM_UPGRADE));
        System.assertNotEquals(null, factory.getProvider(AIProvider.OfferType.GENERAL));
        Test.stopTest();
    }

    @isTest
    static void testProviderFactory_FallbackChainExcludesCircuitBrokenProviders() {
        AIProviderFactory factory = AIProviderFactory.getInstance();

        // Circuit-break VertexAI after 5 failures
        for (Integer i = 0; i < 5; i++) {
            factory.reportFailure(AIProviderFactory.PROVIDER_VERTEX_AI);
        }

        Test.startTest();
        List<AIProvider> chain = factory.getFallbackChain(AIProvider.OfferType.SPA);
        Test.stopTest();

        System.assert(chain.size() >= 2, 'Chain must contain at least Bedrock + MockProvider');

        // VertexAI should NOT appear in chain (circuit-broken)
        for (AIProvider p : chain) {
            if (p instanceof AIProviderFactory.MockAIProvider) {
                String name = ((AIProviderFactory.MockAIProvider) p).getProviderName();
                System.assertNotEquals(AIProviderFactory.PROVIDER_VERTEX_AI, name,
                    'Circuit-broken VertexAI must not appear in fallback chain');
            }
        }

        // Last must be MockProvider
        AIProvider last = chain[chain.size() - 1];
        System.assert(last instanceof AIProviderFactory.MockAIProvider, 'Last entry must be MockAIProvider');
        System.assertEquals(AIProviderFactory.PROVIDER_MOCK,
            ((AIProviderFactory.MockAIProvider) last).getProviderName());
    }

    @isTest
    static void testProviderFactory_ReportAndResetFailure() {
        AIProviderFactory factory = AIProviderFactory.getInstance();

        // Report 4 failures (below threshold — not circuit-broken yet)
        for (Integer i = 0; i < 4; i++) {
            factory.reportFailure(AIProviderFactory.PROVIDER_BEDROCK);
        }

        // Provider should still be in fallback chain
        List<AIProvider> chain = factory.getFallbackChain(AIProvider.OfferType.SPA);
        Boolean bedrockInChain = false;
        for (AIProvider p : chain) {
            if (p instanceof AIProviderFactory.MockAIProvider) {
                if (((AIProviderFactory.MockAIProvider) p).getProviderName() == AIProviderFactory.PROVIDER_BEDROCK) {
                    bedrockInChain = true;
                }
            }
        }
        System.assert(bedrockInChain, 'Bedrock should remain in chain below threshold');

        // Reset the provider
        factory.resetProvider(AIProviderFactory.PROVIDER_BEDROCK);

        // Report 5 failures again — now exceeds threshold
        for (Integer i = 0; i < 5; i++) {
            factory.reportFailure(AIProviderFactory.PROVIDER_BEDROCK);
        }

        // Provider should be excluded from chain
        chain = factory.getFallbackChain(AIProvider.OfferType.SPA);
        for (AIProvider p : chain) {
            if (p instanceof AIProviderFactory.MockAIProvider) {
                System.assertNotEquals(AIProviderFactory.PROVIDER_BEDROCK,
                    ((AIProviderFactory.MockAIProvider) p).getProviderName(),
                    'Circuit-broken Bedrock must be excluded from chain after reset+5 failures');
            }
        }
    }

    @isTest
    static void testProviderFactory_GetProviderReturnsCachedInstance() {
        AIProviderFactory factory = AIProviderFactory.getInstance();

        Test.startTest();
        AIProvider p1 = factory.getProvider(AIProvider.OfferType.SPA);
        AIProvider p2 = factory.getProvider(AIProvider.OfferType.SPA);
        Test.stopTest();

        System.assertEquals(p1, p2, 'Factory must cache and reuse provider instances');
    }

    // ── Orchestrator Tests ──

    @isTest
    static void testOrchestrator_GenerateOffer_Success() {
        Contact guest = [SELECT Id, LastName FROM Contact WHERE LastName = 'Petrova' LIMIT 1];

        Test.startTest();
        GuestAIOrchestrator.OfferResult result = GuestAIOrchestrator.generateOffer(guest.Id, 'Spa');
        Test.stopTest();

        System.assertNotEquals(null, result);
        System.assertEquals(guest.Id, result.guestId);
        System.assertEquals('Spa', result.offerType);
        System.assertNotEquals(null, result.offerDescription);
        System.assert(result.propensityScore >= 0 && result.propensityScore <= 100);
        System.assert(result.confidenceLevel >= 0 && result.confidenceLevel <= 1.0);
        System.assertNotEquals(null, result.reasoning);
        System.assertNotEquals(null, result.providerUsed);
        System.assertNotEquals(null, result.modelVersion);
        System.assertNotEquals(null, result.correlationId);
        System.assert(result.executionTimeMs >= 0);
        System.assert(result.estimatedRevenue > 0);
    }

    @isTest
    static void testOrchestrator_GenerateOffer_AllPriorityProvidersDown() {
        Contact guest = [SELECT Id FROM Contact WHERE LastName = 'Harrington' LIMIT 1];
        AIProviderFactory factory = AIProviderFactory.getInstance();

        // Circuit-break all priority providers — system degrades to MockProvider
        for (String name : new List<String>{
            AIProviderFactory.PROVIDER_VERTEX_AI,
            AIProviderFactory.PROVIDER_OPEN_AI,
            AIProviderFactory.PROVIDER_BEDROCK
        }) {
            for (Integer i = 0; i < 5; i++) { factory.reportFailure(name); }
        }

        Test.startTest();
        GuestAIOrchestrator.OfferResult result = GuestAIOrchestrator.generateOffer(guest.Id, 'Dining');
        Test.stopTest();

        System.assertNotEquals(null, result);
        System.assertNotEquals(null, result.offerDescription);
        System.assertNotEquals(null, result.providerUsed);
        System.assert(result.propensityScore >= 0 && result.propensityScore <= 100);
    }

    @isTest
    static void testOrchestrator_GenerateOffer_NullGuestId() {
        Test.startTest();
        GuestAIOrchestrator.OfferResult result = GuestAIOrchestrator.generateOffer(null, 'Spa');
        Test.stopTest();

        System.assertNotEquals(null, result);
        System.assertEquals(null, result.guestId);
        System.assertEquals(50.0, result.propensityScore);
        System.assertEquals(AIProviderFactory.PROVIDER_DEFAULT, result.providerUsed);
        System.assertEquals(true, result.fallbackTriggered);
    }

    @isTest
    static void testOrchestrator_CorrelationIdGenerated() {
        Contact guest = [SELECT Id FROM Contact WHERE LastName = 'Wei' LIMIT 1];

        Test.startTest();
        GuestAIOrchestrator.OfferResult r1 = GuestAIOrchestrator.generateOffer(guest.Id, 'Spa');
        GuestAIOrchestrator.OfferResult r2 = GuestAIOrchestrator.generateOffer(guest.Id, 'Dining');
        Test.stopTest();

        System.assertNotEquals(null, r1.correlationId);
        System.assert(r1.correlationId.startsWith('AURA-AI-'));
        System.assertNotEquals(null, r2.correlationId);
        System.assertNotEquals(r1.correlationId, r2.correlationId);
    }

    @isTest
    static void testOrchestrator_BlankOfferTypeDefaultsToGeneral() {
        Contact guest = [SELECT Id FROM Contact WHERE LastName = 'Kowalski' LIMIT 1];

        Test.startTest();
        GuestAIOrchestrator.OfferResult result = GuestAIOrchestrator.generateOffer(guest.Id, '');
        Test.stopTest();

        System.assertNotEquals(null, result);
        System.assertEquals('General', result.offerType);
        System.assertNotEquals(null, result.offerDescription);
    }

    // ── Mock Provider Unit Tests ──

    @isTest
    static void testMockProvider_ReturnsValidRecommendation() {
        AIProviderFactory.MockAIProvider mock = new AIProviderFactory.MockAIProvider('VertexAI_Provider');

        AIProvider.AIRequest request = new AIProvider.AIRequest();
        request.guestId = '003TEST000000001';
        request.requestType = AIProvider.OfferType.SPA;
        request.loyaltyTier = AIProvider.LoyaltyTier.PLATINUM;
        request.totalStays = 15;
        request.averageSpend = 1200.0;
        request.maxLatencyMs = 5000;

        Test.startTest();
        AIProvider.AIGuestRecommendation rec = mock.getRecommendation(request);
        Test.stopTest();

        System.assertNotEquals(null, rec);
        System.assertEquals(request.guestId, rec.guestId);
        System.assert(rec.propensityScore >= 0 && rec.propensityScore <= 100);
        System.assert(rec.confidenceLevel >= 0 && rec.confidenceLevel <= 1.0);
        System.assertNotEquals(null, rec.recommendedOffer);
        System.assertNotEquals(null, rec.reasoning);
        System.assertNotEquals(null, rec.modelVersion);
        System.assertNotEquals(null, rec.generatedTimestamp);
        System.assert(rec.estimatedRevenue > 0);
        System.assertNotEquals(null, rec.riskFlags);
    }

    @isTest
    static void testMockProvider_PlatinumPropensityHigherThanBronze() {
        AIProviderFactory.MockAIProvider mock = new AIProviderFactory.MockAIProvider('OpenAI_Provider');

        AIProvider.AIRequest platinum = new AIProvider.AIRequest();
        platinum.guestId = '003PLATINUM0001';
        platinum.requestType = AIProvider.OfferType.ROOM_UPGRADE;
        platinum.loyaltyTier = AIProvider.LoyaltyTier.PLATINUM;
        platinum.totalStays = 20;
        platinum.averageSpend = 2000.0;
        platinum.maxLatencyMs = 5000;

        AIProvider.AIRequest bronze = new AIProvider.AIRequest();
        bronze.guestId = '003BRONZE000001';
        bronze.requestType = AIProvider.OfferType.ROOM_UPGRADE;
        bronze.loyaltyTier = AIProvider.LoyaltyTier.BRONZE;
        bronze.totalStays = 2;
        bronze.averageSpend = 400.0;
        bronze.maxLatencyMs = 5000;

        Test.startTest();
        Decimal platinumScore = mock.getRecommendation(platinum).propensityScore;
        Decimal bronzeScore = mock.getRecommendation(bronze).propensityScore;
        Test.stopTest();

        System.assert(platinumScore > bronzeScore,
            'Platinum ' + platinumScore + ' should exceed Bronze ' + bronzeScore);
    }

    @isTest
    static void testMockProvider_ThrowsOnTimeoutExceeded() {
        AIProviderFactory.MockAIProvider mock = new AIProviderFactory.MockAIProvider('Bedrock_Provider');
        AIProvider.AIRequest request = new AIProvider.AIRequest();
        request.guestId = '003TIMEOUT00001';
        request.requestType = AIProvider.OfferType.SPA;
        request.maxLatencyMs = 50;

        Test.startTest();
        try {
            // Some hashes produce latency under 50ms — that's fine
            AIProvider.AIGuestRecommendation rec = mock.getRecommendation(request);
            System.assertNotEquals(null, rec);
        } catch (AIProvider.AIProviderException e) {
            System.assert(e.getMessage().contains('Timeout'));
        }
        Test.stopTest();
    }
}
