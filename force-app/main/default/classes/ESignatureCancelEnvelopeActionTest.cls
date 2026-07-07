@IsTest
private class ESignatureCancelEnvelopeActionTest {
    @IsTest
    static void cancelActionCancelsManyOpenEnvelopes() {
        Account parent = new Account(Name = 'Cancel Envelope Flow Parent');
        insert parent;

        ContentVersion sentSource = createPdfFile(parent.Id, 'Cancel Sent Source');
        ContentVersion viewedSource = createPdfFile(parent.Id, 'Cancel Viewed Source');
        ContentVersion signedSource = createPdfFile(parent.Id, 'Do Not Cancel Signed Source');

        ESignature_Envelope__c sent = envelope(parent.Id, 'Sent', sentSource, 'sent.signer@example.com');
        ESignature_Envelope__c viewed = envelope(parent.Id, 'Viewed', viewedSource, 'viewed.signer@example.com');
        ESignature_Envelope__c signed = envelope(parent.Id, 'Signed', signedSource, 'signed.signer@example.com');
        insert new List<ESignature_Envelope__c>{ sent, viewed, signed };

        ESignatureCancelEnvelopeAction.Request request = new ESignatureCancelEnvelopeAction.Request();
        request.envelopeId = String.valueOf(sent.Id);
        request.envelopeIds = String.valueOf(viewed.Id) + '\n' + String.valueOf(signed.Id);
        request.cancellationReason = 'Customer asked us to stop the request.';
        request.sendCancellationEmails = false;

        Test.startTest();
        List<ESignatureCancelEnvelopeAction.Response> responses =
            ESignatureCancelEnvelopeAction.cancelEnvelopes(new List<ESignatureCancelEnvelopeAction.Request>{ request });
        Test.stopTest();

        System.assertEquals(1, responses.size(), 'One Flow request should return one summary response.');
        System.assertEquals(false, responses[0].success, 'The signed envelope should be reported as a failure.');
        System.assertEquals(3, responses[0].requestedCount);
        System.assertEquals(2, responses[0].canceledCount);
        System.assertEquals(0, responses[0].skippedCount);
        System.assertEquals(1, responses[0].failedCount);
        System.assert(responses[0].canceledEnvelopeIds.contains(String.valueOf(sent.Id)));
        System.assert(responses[0].canceledEnvelopeIds.contains(String.valueOf(viewed.Id)));
        System.assert(responses[0].failedEnvelopeIds.contains(String.valueOf(signed.Id)));

        Map<Id, ESignature_Envelope__c> envelopes = new Map<Id, ESignature_Envelope__c>([
            SELECT Status__c
            FROM ESignature_Envelope__c
            WHERE Id IN :new Set<Id>{ sent.Id, viewed.Id, signed.Id }
        ]);
        System.assertEquals('Canceled', envelopes.get(sent.Id).Status__c);
        System.assertEquals('Canceled', envelopes.get(viewed.Id).Status__c);
        System.assertEquals('Signed', envelopes.get(signed.Id).Status__c);

        Map<Id, ContentVersion> sources = new Map<Id, ContentVersion>([
            SELECT ESignature_Status__c
            FROM ContentVersion
            WHERE Id IN :new Set<Id>{ sentSource.Id, viewedSource.Id, signedSource.Id }
        ]);
        System.assertEquals('Canceled', sources.get(sentSource.Id).ESignature_Status__c);
        System.assertEquals('Canceled', sources.get(viewedSource.Id).ESignature_Status__c);
        System.assertNotEquals('Canceled', sources.get(signedSource.Id).ESignature_Status__c);

        List<ESignature_Audit_Event__c> audits = [
            SELECT Envelope__c, Event_Type__c, Details__c
            FROM ESignature_Audit_Event__c
            WHERE Envelope__c IN :new Set<Id>{ sent.Id, viewed.Id, signed.Id }
            AND Event_Type__c = 'Canceled'
        ];
        System.assertEquals(2, audits.size(), 'Only the two open envelopes should receive cancellation audit events.');
        for (ESignature_Audit_Event__c audit : audits) {
            System.assert(audit.Details__c.contains('Customer asked us to stop the request.'));
        }
    }

    @IsTest
    static void cancelActionSkipsAlreadyCanceledEnvelope() {
        Account parent = new Account(Name = 'Already Canceled Parent');
        insert parent;
        ContentVersion source = createPdfFile(parent.Id, 'Already Canceled Source');
        ESignature_Envelope__c canceled = envelope(parent.Id, 'Canceled', source, 'already.canceled@example.com');
        insert canceled;

        ESignatureCancelEnvelopeAction.Request request = new ESignatureCancelEnvelopeAction.Request();
        request.envelopeId = String.valueOf(canceled.Id);
        request.sendCancellationEmails = false;

        List<ESignatureCancelEnvelopeAction.Response> responses =
            ESignatureCancelEnvelopeAction.cancelEnvelopes(new List<ESignatureCancelEnvelopeAction.Request>{ request });

        System.assertEquals(true, responses[0].success);
        System.assertEquals(0, responses[0].canceledCount);
        System.assertEquals(1, responses[0].skippedCount);
        System.assertEquals(0, responses[0].failedCount);
        System.assert(responses[0].message.contains('already canceled'));
    }

    @IsTest
    static void cancellationEmailUsesEditableTemplateTokens() {
        Account parent = new Account(Name = 'Cancel Email Parent');
        insert parent;
        ContentVersion source = createPdfFile(parent.Id, 'Cancellation Email Source');
        ESignature_Envelope__c env = envelope(parent.Id, 'Sent', source, 'signer@example.com');
        env.Signer_Name__c = 'Test Signer';
        insert env;

        String html = ESignatureEnvelopeCancellationService.buildCancellationEmailHtml(env, 'Requested by the customer.');

        System.assert(html.contains('The signature request was canceled.'));
        System.assert(html.contains('Cancellation Email Source'));
        System.assert(html.contains('Test Signer'));
        System.assert(html.contains('Requested by the customer.'));
        System.assert(html.contains('{{') == false, 'Rendered fallback email should not leave template tokens behind.');
    }

    private static ContentVersion createPdfFile(Id parentId, String title) {
        ContentVersion source = new ContentVersion(
            Title = title,
            PathOnClient = title + '.pdf',
            VersionData = Blob.valueOf('%PDF-1.4\n1 0 obj\n<</Type/Page>>\nendobj\n%%EOF'),
            FirstPublishLocationId = parentId,
            ESignature_File__c = true
        );
        insert source;
        return [
            SELECT Id, ContentDocumentId, Title, ESignature_Status__c
            FROM ContentVersion
            WHERE Id = :source.Id
        ];
    }

    private static ESignature_Envelope__c envelope(Id parentId, String status, ContentVersion source, String signerEmail) {
        return new ESignature_Envelope__c(
            Status__c = status,
            Parent_Record_Id__c = String.valueOf(parentId),
            Parent_Object_Api_Name__c = 'Account',
            Signer_Name__c = 'Test Signer',
            Signer_Email__c = signerEmail,
            Sender_User__c = UserInfo.getUserId(),
            Source_File_Title__c = source.Title,
            Source_ContentVersion_Id__c = String.valueOf(source.Id),
            Source_ContentDocument_Id__c = String.valueOf(source.ContentDocumentId)
        );
    }
}
