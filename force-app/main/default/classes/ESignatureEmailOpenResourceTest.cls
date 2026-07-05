@IsTest
private class ESignatureEmailOpenResourceTest {
    @IsTest
    static void getPixelReturnsPixelForValidToken() {
        String token = 'email-open-token';
        ESignature_Envelope__c env = new ESignature_Envelope__c(
            Envelope_Status__c = 'Sent',
            Secure_Token_Hash__c = ESignatureUtil.hashToken(token),
            Signer_Name__c = 'Email Opener',
            Signer_Email__c = 'signer@example.com',
            Sender_User__c = UserInfo.getUserId(),
            Source_File_Title__c = 'Email Open Agreement'
        );
        insert env;

        RestRequest request = new RestRequest();
        request.requestUri = '/services/apexrest/ESignature/v1/email-open';
        request.httpMethod = 'GET';
        request.params.put('t', token);
        request.headers.put('User-Agent', 'Unit Test Agent');
        request.headers.put('X-Forwarded-For', '203.0.113.25');
        RestContext.request = request;
        RestContext.response = new RestResponse();

        ESignatureEmailOpenResource.getPixel();

        System.assertEquals(200, RestContext.response.statusCode);
        System.assertEquals('image/gif', RestContext.response.headers.get('Content-Type'));
        System.assertNotEquals(null, RestContext.response.responseBody, 'Tracking endpoint should always return a pixel.');
        System.assertEquals(0, [
            SELECT COUNT()
            FROM ESignature_Audit_Event__c
            WHERE Envelope__c = :env.Id
        ], 'The REST resource should only publish the command; the command processor handles audit rows.');
    }

    @IsTest
    static void emailOpenedCommandAuditsEmailOpen() {
        String token = 'email-open-command-token';
        String tokenHash = ESignatureUtil.hashToken(token);
        ESignature_Envelope__c env = new ESignature_Envelope__c(
            Envelope_Status__c = 'Sent',
            Secure_Token_Hash__c = tokenHash,
            Signer_Name__c = 'Email Opener',
            Signer_Email__c = 'signer@example.com',
            Sender_User__c = UserInfo.getUserId(),
            Source_File_Title__c = 'Email Open Agreement'
        );
        insert env;

        Test.startTest();
        Database.SaveResult result = EventBus.publish(new ESignature_Command__e(
            Action__c = 'email-opened',
            Token_Hash__c = tokenHash,
            Payload_JSON__c = '{"userAgent":"Unit Test Agent","ipAddress":"203.0.113.25"}'
        ));
        System.assert(result.isSuccess(), 'Email opened command should publish successfully.');
        Test.getEventBus().deliver();
        Test.stopTest();

        ESignature_Audit_Event__c audit = [
            SELECT Event_Type__c, Actor_Email__c, User_Agent__c, IP_Address__c
            FROM ESignature_Audit_Event__c
            WHERE Envelope__c = :env.Id
            AND Event_Type__c = 'Email Opened'
            LIMIT 1
        ];
        System.assertEquals('Email Opened', audit.Event_Type__c);
        System.assertEquals('signer@example.com', audit.Actor_Email__c);
        System.assertEquals('Unit Test Agent', audit.User_Agent__c);
        System.assertEquals('203.0.113.25', audit.IP_Address__c);
    }

    @IsTest
    static void getPixelReturnsPixelForInvalidTokenWithoutAudit() {
        RestRequest request = new RestRequest();
        request.requestUri = '/services/apexrest/ESignature/v1/email-open';
        request.httpMethod = 'GET';
        request.params.put('t', 'missing-token');
        RestContext.request = request;
        RestContext.response = new RestResponse();

        ESignatureEmailOpenResource.getPixel();

        System.assertEquals(200, RestContext.response.statusCode);
        System.assertEquals('image/gif', RestContext.response.headers.get('Content-Type'));
        System.assertEquals(0, [SELECT COUNT() FROM ESignature_Audit_Event__c]);
    }
}
