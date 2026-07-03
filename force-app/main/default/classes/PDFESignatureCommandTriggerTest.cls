@IsTest
private class PDFESignatureCommandTriggerTest {
    @IsTest
    static void viewedCommandUpdatesEnvelopeThroughTrigger() {
        String token = 'test-token';
        String tokenHash = PDFESignatureUtil.hashToken(token);
        ESignature_Envelope__c env = new ESignature_Envelope__c(
            Envelope_Status__c = 'Sent',
            Secure_Token_Hash__c = tokenHash,
            Signer_Email__c = 'signer@example.com'
        );
        insert env;

        Test.startTest();
        Database.SaveResult result = EventBus.publish(new ESignature_Command__e(
            Action__c = 'viewed',
            Token_Hash__c = tokenHash,
            Payload_JSON__c = '{"userAgent":"Unit Test","ipAddress":"127.0.0.1"}'
        ));
        System.assert(result.isSuccess(), 'Platform event should publish successfully.');
        Test.getEventBus().deliver();
        Test.stopTest();

        env = [
            SELECT Envelope_Status__c, Viewed_At__c
            FROM ESignature_Envelope__c
            WHERE Id = :env.Id
        ];
        System.assertEquals('Viewed', env.Envelope_Status__c);
        System.assertNotEquals(null, env.Viewed_At__c);

        System.assertEquals(1, [
            SELECT COUNT()
            FROM ESignature_Audit_Event__c
            WHERE Envelope__c = :env.Id
            AND Event_Type__c = 'Viewed'
        ]);
    }

    @IsTest
    static void signedCommandWithMissingRequiredFieldMarksEnvelopeError() {
        String token = 'required-field-token';
        String tokenHash = PDFESignatureUtil.hashToken(token);
        ESignature_Envelope__c env = new ESignature_Envelope__c(
            Envelope_Status__c = 'Viewed',
            Secure_Token_Hash__c = tokenHash,
            Signer_Name__c = 'Derek Hawley',
            Signer_Email__c = 'signer@example.com',
            Signer_Title__c = 'President'
        );
        insert env;

        insert new ESignature_Field__c(
            Envelope__c = env.Id,
            Field_Type__c = 'Text',
            Label__c = 'Required Text',
            Page_Number__c = 1,
            Pdf_X__c = 100,
            Pdf_Y__c = 200,
            Pdf_Width__c = 180,
            Pdf_Height__c = 32,
            Page_Width_Points__c = 612,
            Page_Height_Points__c = 792,
            Required__c = true,
            Sequence__c = 1
        );

        Map<String, Object> payload = new Map<String, Object>{
            'typedName' => 'Derek Hawley',
            'signerTitle' => 'President',
            'signerFieldsJson' => '[]'
        };

        Test.startTest();
        Database.SaveResult result = EventBus.publish(new ESignature_Command__e(
            Action__c = 'signed',
            Token_Hash__c = tokenHash,
            Payload_JSON__c = JSON.serialize(payload)
        ));
        System.assert(result.isSuccess(), 'Platform event should publish successfully.');
        Test.getEventBus().deliver();
        Test.stopTest();

        env = [
            SELECT Envelope_Status__c, Error_Message__c
            FROM ESignature_Envelope__c
            WHERE Id = :env.Id
        ];
        System.assertEquals('Error', env.Envelope_Status__c, 'Envelope should not finalize when a required field is missing.');
        System.assert(env.Error_Message__c.contains('Required Text'), 'Error should name the missing required field.');
    }

    @IsTest
    static void declinedCommandUpdatesEnvelopeThroughTrigger() {
        String token = 'declined-token';
        String tokenHash = PDFESignatureUtil.hashToken(token);
        ContentVersion source = createSourceFile('Declined Source');
        ESignature_Envelope__c env = new ESignature_Envelope__c(
            Envelope_Status__c = 'Viewed',
            Secure_Token_Hash__c = tokenHash,
            Signer_Email__c = 'signer@example.com',
            Source_ContentVersion_Id__c = String.valueOf(source.Id),
            Source_ContentDocument_Id__c = String.valueOf(source.ContentDocumentId)
        );
        insert env;

        Test.startTest();
        Database.SaveResult result = EventBus.publish(new ESignature_Command__e(
            Action__c = 'declined',
            Token_Hash__c = tokenHash,
            Payload_JSON__c = '{"declineReason":"No longer needed"}'
        ));
        System.assert(result.isSuccess(), 'Platform event should publish successfully.');
        Test.getEventBus().deliver();
        Test.stopTest();

        env = [
            SELECT Envelope_Status__c, Decline_Reason__c
            FROM ESignature_Envelope__c
            WHERE Id = :env.Id
        ];
        System.assertEquals('Declined', env.Envelope_Status__c);
        System.assertEquals('No longer needed', env.Decline_Reason__c);
        source = [SELECT E_Signature_Status__c FROM ContentVersion WHERE Id = :source.Id];
        System.assertEquals('Canceled', source.E_Signature_Status__c, 'Declining should stamp the source file status.');
    }

    @IsTest
    static void delegatedCommandTransfersSignerAndRotatesToken() {
        String token = 'delegated-token';
        String tokenHash = PDFESignatureUtil.hashToken(token);
        ContentVersion source = createSourceFile('Delegated Source');
        ESignature_Envelope__c env = new ESignature_Envelope__c(
            Envelope_Status__c = 'Viewed',
            Secure_Token_Hash__c = tokenHash,
            Signer_Name__c = 'Original Signer',
            Signer_Email__c = 'original@example.com',
            Signer_Title__c = 'Owner',
            Viewed_At__c = System.now(),
            Public_Signing_URL__c = 'https://example.com/old-link',
            Source_File_Title__c = 'Delegated Agreement',
            Source_ContentVersion_Id__c = String.valueOf(source.Id),
            Source_ContentDocument_Id__c = String.valueOf(source.ContentDocumentId)
        );
        insert env;

        Map<String, Object> payload = new Map<String, Object>{
            'delegateEmail' => 'delegate@example.com',
            'delegateName' => 'Delegate Signer',
            'delegateMessage' => 'Please review and sign this agreement.'
        };

        Test.startTest();
        Database.SaveResult result = EventBus.publish(new ESignature_Command__e(
            Action__c = 'delegated',
            Token_Hash__c = tokenHash,
            Payload_JSON__c = JSON.serialize(payload)
        ));
        System.assert(result.isSuccess(), 'Platform event should publish successfully.');
        Test.getEventBus().deliver();
        Test.stopTest();

        env = [
            SELECT Envelope_Status__c, Secure_Token_Hash__c, Signer_Name__c, Signer_Email__c,
                   Signer_Title__c, Sent_At__c, Viewed_At__c, Public_Signing_URL__c, Error_Message__c
            FROM ESignature_Envelope__c
            WHERE Id = :env.Id
        ];
        System.assertEquals('Sent', env.Envelope_Status__c, 'Delegated envelope should be sent to the delegate. Error: ' + env.Error_Message__c);
        System.assertNotEquals(tokenHash, env.Secure_Token_Hash__c, 'Delegation should invalidate the original signer token.');
        System.assertEquals('Delegate Signer', env.Signer_Name__c);
        System.assertEquals('delegate@example.com', env.Signer_Email__c);
        System.assertEquals(null, env.Signer_Title__c);
        System.assertNotEquals(null, env.Sent_At__c);
        System.assertEquals(null, env.Viewed_At__c, 'The delegate should get their own viewed event.');
        System.assert(env.Public_Signing_URL__c.contains('/PDFESignaturePage?t='), 'Delegate should receive a fresh signing URL.');
        source = [SELECT E_Signature_Status__c FROM ContentVersion WHERE Id = :source.Id];
        System.assertEquals('Sent', source.E_Signature_Status__c, 'Delegating should keep the source file in sent status.');

        ESignature_Audit_Event__c audit = [
            SELECT Actor_Email__c, Details__c
            FROM ESignature_Audit_Event__c
            WHERE Envelope__c = :env.Id
            AND Event_Type__c = 'Delegated'
            LIMIT 1
        ];
        System.assertEquals('original@example.com', audit.Actor_Email__c, 'Delegation audit should be attributed to the original signer.');
        System.assert(audit.Details__c.contains('delegate@example.com'), 'Delegation audit should include the delegate email.');
    }

    @IsTest
    static void signedCommandWithoutTypedNameMarksEnvelopeError() {
        String token = 'missing-name-token';
        String tokenHash = PDFESignatureUtil.hashToken(token);
        ESignature_Envelope__c env = new ESignature_Envelope__c(
            Envelope_Status__c = 'Viewed',
            Secure_Token_Hash__c = tokenHash,
            Signer_Email__c = 'signer@example.com'
        );
        insert env;

        Test.startTest();
        Database.SaveResult result = EventBus.publish(new ESignature_Command__e(
            Action__c = 'signed',
            Token_Hash__c = tokenHash,
            Payload_JSON__c = '{"typedName":"","signerTitle":"","signerFieldsJson":"[]"}'
        ));
        System.assert(result.isSuccess(), 'Platform event should publish successfully.');
        Test.getEventBus().deliver();
        Test.stopTest();

        env = [
            SELECT Envelope_Status__c, Error_Message__c
            FROM ESignature_Envelope__c
            WHERE Id = :env.Id
        ];
        System.assertEquals('Error', env.Envelope_Status__c);
        System.assert(env.Error_Message__c.contains('Type your full legal name.'), 'Error should explain the missing signer name.');
    }

    private static ContentVersion createSourceFile(String title) {
        ContentVersion source = new ContentVersion(
            Title = title,
            PathOnClient = title + '.pdf',
            VersionData = Blob.valueOf('%PDF-1.4\n%source\n%%EOF'),
            E_Signature_File__c = true
        );
        insert source;
        return [SELECT Id, ContentDocumentId FROM ContentVersion WHERE Id = :source.Id];
    }
}
