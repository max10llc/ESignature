@IsTest
private class ESignatureCommandTriggerTest {
    @IsTest
    static void viewedCommandUpdatesEnvelopeThroughTrigger() {
        String token = 'test-token';
        String tokenHash = ESignatureUtil.hashToken(token);
        ESignature_Envelope__c env = new ESignature_Envelope__c(
            Status__c = 'Sent',
            Secure_Token_Hash__c = tokenHash,
            Signer_Email__c = 'signer@example.com',
            Sender_User__c = UserInfo.getUserId()
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
            SELECT Status__c, Viewed_At__c
            FROM ESignature_Envelope__c
            WHERE Id = :env.Id
        ];
        System.assertEquals('Viewed', env.Status__c);
        System.assertNotEquals(null, env.Viewed_At__c);

        System.assertEquals(1, [
            SELECT COUNT()
            FROM ESignature_Audit_Event__c
            WHERE Envelope__c = :env.Id
            AND Event_Type__c = 'Viewed'
        ]);
    }

    @IsTest
    static void viewedCommandNotifiesSenderEveryDocumentOpen() {
        Account parent = new Account(Name = 'Viewed Notification Parent');
        insert parent;
        String token = 'repeat-view-token';
        String tokenHash = ESignatureUtil.hashToken(token);
        ESignature_Envelope__c env = new ESignature_Envelope__c(
            Status__c = 'Viewed',
            Viewed_At__c = System.now().addMinutes(-5),
            Secure_Token_Hash__c = tokenHash,
            Signer_Name__c = 'Viewing Signer',
            Signer_Email__c = 'viewer@example.com',
            Sender_User__c = UserInfo.getUserId(),
            Parent_Record_Id__c = String.valueOf(parent.Id),
            Parent_Object_Api_Name__c = 'Account',
            Source_File_Title__c = 'Viewed Notification Agreement'
        );
        insert env;

        Map<String, Object> payload = new Map<String, Object>{
            'userAgent' => 'Unit Test Browser',
            'ipAddress' => '203.0.113.44'
        };

        String documentHtml = ESignatureCommandProcessor.buildDocumentOpenedNotificationEmailHtml(env, payload);
        System.assert(documentHtml.contains('Viewed Notification Agreement'), 'Document opened notification should identify the document.');
        System.assert(documentHtml.contains('Viewing Signer'), 'Document opened notification should identify the signer.');
        System.assert(documentHtml.contains('/lightning/r/Account/' + String.valueOf(parent.Id) + '/view'), 'Document opened notification should link to the Salesforce record.');

        String emailHtml = ESignatureCommandProcessor.buildEmailOpenedNotificationEmailHtml(env, payload);
        System.assert(emailHtml.contains('initial signature request email'), 'Email opened notification should describe the email-open event.');
        System.assert(!emailHtml.contains('{{IPAddress}}'), 'Email opened notification should replace request context tokens when present.');

        Test.startTest();
        Database.SaveResult open = EventBus.publish(new ESignature_Command__e(
            Action__c = 'viewed',
            Token_Hash__c = tokenHash,
            Payload_JSON__c = JSON.serialize(payload)
        ));
        System.assert(open.isSuccess(), 'Repeat view command should publish successfully.');
        Test.getEventBus().deliver();
        Test.stopTest();

        Map<String, Integer> countsByType = new Map<String, Integer>();
        for (AggregateResult result : [
            SELECT Event_Type__c eventType, COUNT(Id) eventCount
            FROM ESignature_Audit_Event__c
            WHERE Envelope__c = :env.Id
            GROUP BY Event_Type__c
        ]) {
            countsByType.put((String) result.get('eventType'), (Integer) result.get('eventCount'));
        }
        System.assertEquals(null, countsByType.get('Viewed'), 'Repeat document opens should not create another Viewed audit.');
        System.assertEquals(1, countsByType.get('Document Opened'), 'Repeat document opens should be audited separately.');
    }

    @IsTest
    static void signedCommandWithMissingRequiredFieldMarksEnvelopeError() {
        String token = 'required-field-token';
        String tokenHash = ESignatureUtil.hashToken(token);
        ESignature_Envelope__c env = new ESignature_Envelope__c(
            Status__c = 'Viewed',
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
            SELECT Status__c, Error_Message__c
            FROM ESignature_Envelope__c
            WHERE Id = :env.Id
        ];
        System.assertEquals('Error', env.Status__c, 'Envelope should not finalize when a required field is missing.');
        System.assert(env.Error_Message__c.contains('Required Text'), 'Error should name the missing required field.');
    }

    @IsTest
    static void submittedFieldValueMapExpandsSharedInitialsImageToken() {
        String initialsImage = 'data:image/jpeg;base64,abc123';
        ESignature_Envelope__c env = new ESignature_Envelope__c(
            Status__c = 'Viewed',
            Secure_Token_Hash__c = ESignatureUtil.hashToken('initials-token'),
            Signer_Name__c = 'Derek Hawley',
            Signer_Email__c = 'signer@example.com'
        );
        insert env;
        ESignature_Field__c initialsField = new ESignature_Field__c(
            Envelope__c = env.Id,
            Field_Type__c = 'Initials',
            Label__c = 'Initials',
            Page_Number__c = 1,
            Pdf_X__c = 100,
            Pdf_Y__c = 200,
            Pdf_Width__c = 80,
            Pdf_Height__c = 24,
            Page_Width_Points__c = 612,
            Page_Height_Points__c = 792,
            Required__c = true,
            Sequence__c = 1
        );
        insert initialsField;

        String rawJson = JSON.serialize(new List<Object>{
            new Map<String, Object>{
                'id' => String.valueOf(initialsField.Id),
                'value' => '__ESIGN_INITIALS_IMAGE__'
            }
        });

        Map<Id, String> submittedValues = ESignatureCommandProcessor.submittedFieldValueMap(rawJson, initialsImage);

        System.assertEquals(initialsImage, submittedValues.get(initialsField.Id), 'Shared initials image token should expand before fields are saved.');
    }

    @IsTest
    static void declinedCommandUpdatesEnvelopeThroughTrigger() {
        String token = 'declined-token';
        String tokenHash = ESignatureUtil.hashToken(token);
        ContentVersion source = createSourceFile('Declined Source');
        ESignature_Envelope__c env = new ESignature_Envelope__c(
            Status__c = 'Viewed',
            Secure_Token_Hash__c = tokenHash,
            Signer_Name__c = 'Declining Signer',
            Signer_Email__c = 'signer@example.com',
            Sender_User__c = UserInfo.getUserId(),
            Source_File_Title__c = 'Declined Agreement',
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
            SELECT Status__c, Decline_Reason__c
            FROM ESignature_Envelope__c
            WHERE Id = :env.Id
        ];
        System.assertEquals('Declined', env.Status__c);
        System.assertEquals('No longer needed', env.Decline_Reason__c);
        source = [SELECT ESignature_Status__c FROM ContentVersion WHERE Id = :source.Id];
        System.assertEquals('Canceled', source.ESignature_Status__c, 'Declining should stamp the source file status.');
    }

    @IsTest
    static void declineNotificationIncludesSignerAndSender() {
        ESignature_Envelope__c env = new ESignature_Envelope__c(
            Signer_Name__c = 'Declining Signer',
            Signer_Email__c = 'signer@example.com',
            Sender_User__c = UserInfo.getUserId(),
            Source_File_Title__c = 'Declined Agreement',
            Decline_Reason__c = 'No longer needed'
        );

        List<String> recipients = ESignatureCommandProcessor.declineNotificationRecipients(env);
        System.assert(recipients.contains('signer@example.com'), 'Signer should receive the decline notification.');
        System.assert(recipients.contains(UserInfo.getUserEmail()), 'Salesforce sender should receive the decline notification.');

        String html = ESignatureCommandProcessor.buildDeclineNotificationEmailHtml(env);
        System.assert(html.contains('<table role="presentation" width="100%"'), 'Decline email should use the same table-based shell as the request email.');
        System.assert(html.contains('/resource/Kaizon_Solutions_Logo'), 'Decline email should render the configured company logo.');
        System.assert(html.contains('Declined Agreement'), 'Notification should identify the document.');
        System.assert(html.contains('Declining Signer'), 'Notification should identify the signer.');
        System.assert(html.contains('No longer needed'), 'Notification should include the decline reason.');
    }

    @IsTest
    static void delegatedCommandTransfersSignerAndRotatesToken() {
        String token = 'delegated-token';
        String tokenHash = ESignatureUtil.hashToken(token);
        ContentVersion source = createSourceFile('Delegated Source');
        ESignature_Envelope__c env = new ESignature_Envelope__c(
            Status__c = 'Viewed',
            Secure_Token_Hash__c = tokenHash,
            Signer_Name__c = 'Original Signer',
            Signer_Email__c = 'original@example.com',
            Signer_Title__c = 'Owner',
            Sender_User__c = UserInfo.getUserId(),
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
            SELECT Status__c, Secure_Token_Hash__c, Signer_Name__c, Signer_Email__c,
                   Signer_Title__c, Sent_At__c, Viewed_At__c, Public_Signing_URL__c, Error_Message__c
            FROM ESignature_Envelope__c
            WHERE Id = :env.Id
        ];
        System.assertEquals('Sent', env.Status__c, 'Delegated envelope should be sent to the delegate. Error: ' + env.Error_Message__c);
        System.assertNotEquals(tokenHash, env.Secure_Token_Hash__c, 'Delegation should invalidate the original signer token.');
        System.assertEquals('Delegate Signer', env.Signer_Name__c);
        System.assertEquals('delegate@example.com', env.Signer_Email__c);
        System.assertEquals(null, env.Signer_Title__c);
        System.assertNotEquals(null, env.Sent_At__c);
        System.assertEquals(null, env.Viewed_At__c, 'The delegate should get their own viewed event.');
        System.assert(env.Public_Signing_URL__c.contains('/ESignaturePage?t='), 'Delegate should receive a fresh signing URL.');
        source = [SELECT ESignature_Status__c FROM ContentVersion WHERE Id = :source.Id];
        System.assertEquals('Sent', source.ESignature_Status__c, 'Delegating should keep the source file in sent status.');

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
    static void delegateEmailsUseBrandedSeparateTemplates() {
        ESignature_Envelope__c env = new ESignature_Envelope__c(
            Signer_Name__c = 'Delegate Signer',
            Signer_Email__c = 'delegate@example.com',
            Sender_User__c = UserInfo.getUserId(),
            Source_File_Title__c = 'Delegated Agreement',
            Expires_At__c = Datetime.newInstance(2026, 7, 27, 12, 0, 0)
        );

        String delegateHtml = ESignatureCommandProcessor.buildDelegateSignerEmailHtml(
            env,
            'https://example.com/signatures/apex/ESignaturePage?t=newtoken',
            'Please review and sign this agreement.',
            'Original Signer',
            'original@example.com'
        );
        String originalSignerHtml = ESignatureCommandProcessor.buildOriginalSignerDelegationEmailHtml(
            env,
            'Please review and sign this agreement.',
            'Original Signer',
            'original@example.com'
        );
        String salesforceUserHtml = ESignatureCommandProcessor.buildSalesforceUserDelegationEmailHtml(
            env,
            'Please review and sign this agreement.',
            'Original Signer',
            'original@example.com'
        );

        System.assert(delegateHtml.contains('<table role="presentation" width="100%"'), 'Delegate email should use the branded shell.');
        System.assert(delegateHtml.contains('/resource/Kaizon_Solutions_Logo'), 'Delegate email should render the configured company logo.');
        System.assert(delegateHtml.contains('Review &amp; Sign Document'), 'Delegate email should include the signing call to action.');
        System.assert(delegateHtml.contains('https://example.com/signatures/apex/ESignaturePage?t=newtoken'), 'Delegate email should include the fresh signing URL.');
        System.assert(delegateHtml.contains('Original Signer'), 'Delegate email should identify the original signer.');
        System.assert(delegateHtml.contains('Please review and sign this agreement.'), 'Delegate email should include the delegate message.');

        System.assert(originalSignerHtml.contains('<table role="presentation" width="100%"'), 'Original signer email should use the branded shell.');
        System.assert(originalSignerHtml.contains('Your signature request was delegated to Delegate Signer'), 'Original signer email should confirm delegation.');
        System.assert(originalSignerHtml.contains('Your original signing link is no longer active'), 'Original signer email should explain the old link.');

        System.assert(salesforceUserHtml.contains('<table role="presentation" width="100%"'), 'Salesforce user email should use the branded shell.');
        System.assert(salesforceUserHtml.contains('Original Signer'), 'Salesforce user email should identify the original signer.');
        System.assert(salesforceUserHtml.contains('Delegate Signer'), 'Salesforce user email should identify the delegated signer.');
        System.assert(salesforceUserHtml.contains('Delegated Agreement'), 'Salesforce user email should identify the document.');
    }

    @IsTest
    static void signedCommandWithoutTypedNameMarksEnvelopeError() {
        String token = 'missing-name-token';
        String tokenHash = ESignatureUtil.hashToken(token);
        ESignature_Envelope__c env = new ESignature_Envelope__c(
            Status__c = 'Viewed',
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
            SELECT Status__c, Error_Message__c
            FROM ESignature_Envelope__c
            WHERE Id = :env.Id
        ];
        System.assertEquals('Error', env.Status__c);
        System.assert(env.Error_Message__c.contains('Type your full legal name.'), 'Error should explain the missing signer name.');
    }

    @IsTest
    static void signedCommandForCanceledEnvelopeIsIgnored() {
        String token = 'canceled-sign-token';
        String tokenHash = ESignatureUtil.hashToken(token);
        ESignature_Envelope__c env = new ESignature_Envelope__c(
            Status__c = 'Canceled',
            Secure_Token_Hash__c = tokenHash,
            Signer_Email__c = 'signer@example.com'
        );
        insert env;

        Test.startTest();
        Database.SaveResult result = EventBus.publish(new ESignature_Command__e(
            Action__c = 'signed',
            Token_Hash__c = tokenHash,
            Payload_JSON__c = '{"typedName":"Derek Hawley","signerTitle":"","signerFieldsJson":"[]"}'
        ));
        System.assert(result.isSuccess(), 'Platform event should publish successfully.');
        Test.getEventBus().deliver();
        Test.stopTest();

        env = [
            SELECT Status__c, Signed_At__c
            FROM ESignature_Envelope__c
            WHERE Id = :env.Id
        ];
        System.assertEquals('Canceled', env.Status__c, 'Canceled envelopes should not be reopened by an old signing page.');
        System.assertEquals(null, env.Signed_At__c, 'Canceled envelopes should not be marked signed.');
        System.assertEquals(0, [
            SELECT COUNT()
            FROM ESignature_Audit_Event__c
            WHERE Envelope__c = :env.Id
            AND Event_Type__c = 'Signed'
        ]);
    }

    private static ContentVersion createSourceFile(String title) {
        ContentVersion source = new ContentVersion(
            Title = title,
            PathOnClient = title + '.pdf',
            VersionData = Blob.valueOf('%PDF-1.4\n%source\n%%EOF'),
            ESignature_File__c = true
        );
        insert source;
        return [SELECT Id, ContentDocumentId FROM ContentVersion WHERE Id = :source.Id];
    }
}
