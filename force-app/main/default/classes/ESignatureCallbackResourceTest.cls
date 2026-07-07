@IsTest
private class ESignatureCallbackResourceTest {
    @IsTest
    static void postResultRequiresEnvelopeId() {
        setRestRequest(new Map<String, Object>{
            'success' => true
        });

        ESignatureFinalizerCallbackResource.postResult();

        System.assertEquals(400, RestContext.response.statusCode);
        Map<String, Object> body = responseBody();
        System.assertEquals(false, body.get('success'));
        System.assert(String.valueOf(body.get('message')).contains('envelopeId'));
    }

    @IsTest
    static void postResultRejectsMissingSecret() {
        ESignature_Envelope__c env = createEnvelope();
        setRestRequest(new Map<String, Object>{
            'envelopeId' => String.valueOf(env.Id),
            'success' => false,
            'message' => 'Do not apply this callback.'
        }, false);

        ESignatureFinalizerCallbackResource.postResult();

        System.assertEquals(401, RestContext.response.statusCode);
        Map<String, Object> body = responseBody();
        System.assertEquals(false, body.get('success'));
        System.assert(String.valueOf(body.get('message')).contains('Unauthorized'));
        env = [
            SELECT Status__c, Error_Message__c
            FROM ESignature_Envelope__c
            WHERE Id = :env.Id
        ];
        System.assertEquals('Finalizing', env.Status__c);
        System.assertEquals(null, env.Error_Message__c);
    }

    @IsTest
    static void postResultFailureMarksEnvelopeError() {
        ESignature_Envelope__c env = createEnvelope();
        setRestRequest(new Map<String, Object>{
            'envelopeId' => String.valueOf(env.Id),
            'success' => false,
            'message' => 'Finalizer failed during processing.'
        });

        ESignatureFinalizerCallbackResource.postResult();

        System.assertEquals(200, RestContext.response.statusCode);
        env = [
            SELECT Status__c, Error_Message__c
            FROM ESignature_Envelope__c
            WHERE Id = :env.Id
        ];
        System.assertEquals('Error', env.Status__c);
        System.assertEquals('Finalizer failed during processing.', env.Error_Message__c);
    }

    @IsTest
    static void postResultCompletesWithBase64Pdf() {
        Account parent = new Account(Name = 'Callback Parent');
        insert parent;
        ESignature_Envelope__c env = createEnvelope();
        env.Parent_Record_Id__c = String.valueOf(parent.Id);
        update env;
        String finalPdfBase64 = EncodingUtil.base64Encode(Blob.valueOf('%PDF-1.4\n%%EOF'));

        setRestRequest(new Map<String, Object>{
            'envelopeId' => String.valueOf(env.Id),
            'success' => true,
            'finalPdfBase64' => finalPdfBase64,
            'fileName' => 'Callback Signed.pdf',
            'message' => 'Callback finalized the PDF.'
        });

        ESignatureFinalizerCallbackResource.postResult();

        System.assertEquals(200, RestContext.response.statusCode);
        env = [
            SELECT Status__c, Final_ContentVersion_Id__c, Final_ContentDocument_Id__c, Completion_Message__c
            FROM ESignature_Envelope__c
            WHERE Id = :env.Id
        ];
        System.assertEquals('Signed', env.Status__c);
        System.assertNotEquals(null, env.Final_ContentVersion_Id__c);
        System.assertNotEquals(null, env.Final_ContentDocument_Id__c);
        System.assertEquals('Callback finalized the PDF.', env.Completion_Message__c);
    }

    private static ESignature_Envelope__c createEnvelope() {
        ESignature_Envelope__c env = new ESignature_Envelope__c(
            Status__c = 'Finalizing',
            Signer_Email__c = 'signer@example.com'
        );
        insert env;
        return env;
    }

    private static void setRestRequest(Map<String, Object> body) {
        setRestRequest(body, true);
    }

    private static void setRestRequest(Map<String, Object> body, Boolean includeSecret) {
        RestRequest request = new RestRequest();
        request.requestUri = '/services/apexrest/ESignature/v1/finalizer-callback';
        request.httpMethod = 'POST';
        request.requestBody = Blob.valueOf(JSON.serialize(body));
        String secret = ESignatureUtil.getSettings().Finalizer_Callback_Secret__c;
        if (includeSecret == true && !String.isBlank(secret)) {
            request.headers.put('X-PDF-ESignature-Secret', secret);
        }
        RestContext.request = request;
        RestContext.response = new RestResponse();
    }

    private static Map<String, Object> responseBody() {
        return (Map<String, Object>) JSON.deserializeUntyped(RestContext.response.responseBody.toString());
    }
}
