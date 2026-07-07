@IsTest
private class ESignatureSendControllerTest {
    private class DraftFixture {
        Id parentId;
        ESignature_Envelope__c envelope;
        ESignature_Field__c field;
    }

    @IsTest
    static void getDraftEnvelopesReturnsCurrentDraftsWithRefreshKey() {
        DraftFixture fixture = createDraftFixture();

        List<ESignatureSendController.EnvelopeDTO> drafts =
            ESignatureSendController.getDraftEnvelopes(String.valueOf(fixture.parentId), 'first-refresh');

        System.assertEquals(1, drafts.size(), 'One draft envelope should be returned.');
        System.assertEquals(String.valueOf(fixture.envelope.Id), drafts[0].id);
        System.assertEquals('Draft', drafts[0].status);
        System.assertEquals(1, drafts[0].fieldCount);
        System.assertEquals('Send Controller Source', drafts[0].title);
    }

    @IsTest
    static void getSignerContactsReturnsAccountContactsWithEmail() {
        Account parent = new Account(Name = 'Signer Contact Account');
        insert parent;
        Contact contactWithEmail = new Contact(
            FirstName = 'Ada',
            LastName = 'Signer',
            Email = 'ada.signer@example.com',
            Title = 'Director',
            AccountId = parent.Id
        );
        Contact contactWithoutEmail = new Contact(
            FirstName = 'No',
            LastName = 'Email',
            AccountId = parent.Id
        );
        insert new List<Contact>{ contactWithEmail, contactWithoutEmail };

        List<ESignatureSendController.SignerContactDTO> contacts =
            ESignatureSendController.getSignerContacts(String.valueOf(parent.Id), 'contacts-refresh');

        System.assertEquals(1, contacts.size(), 'Only account contacts with email addresses should be returned.');
        System.assertEquals(String.valueOf(contactWithEmail.Id), contacts[0].id);
        System.assertEquals('Ada Signer', contacts[0].name);
        System.assertEquals('ada.signer@example.com', contacts[0].email);
        System.assertEquals('Director', contacts[0].title);
        System.assert(contacts[0].label.contains('ada.signer@example.com'), 'The picklist label should include the email address.');
    }

    @IsTest
    static void getSignerContactsResolvesOpportunityAccount() {
        Account parent = new Account(Name = 'Opportunity Signer Account');
        insert parent;
        Opportunity opportunity = new Opportunity(
            Name = 'Signer Opportunity',
            StageName = 'Prospecting',
            CloseDate = Date.today().addDays(30),
            AccountId = parent.Id
        );
        insert opportunity;
        Contact signer = new Contact(
            FirstName = 'Olivia',
            LastName = 'Opportunity',
            Email = 'olivia@example.com',
            AccountId = parent.Id
        );
        insert signer;

        List<ESignatureSendController.SignerContactDTO> contacts =
            ESignatureSendController.getSignerContacts(String.valueOf(opportunity.Id), 'opportunity-refresh');

        System.assertEquals(1, contacts.size(), 'Opportunity records should resolve contacts from their account.');
        System.assertEquals(String.valueOf(signer.Id), contacts[0].id);
    }

    @IsTest
    static void getSignerContactsIncludesIndirectAccountContactRelationships() {
        Account relatedAccount = new Account(Name = 'Relationship Signer Account');
        Account primaryAccount = new Account(Name = 'Primary Contact Account');
        insert new List<Account>{ relatedAccount, primaryAccount };

        Contact directSigner = new Contact(
            FirstName = 'Direct',
            LastName = 'Signer',
            Email = 'direct.signer@example.com',
            AccountId = relatedAccount.Id
        );
        Contact indirectSigner = new Contact(
            FirstName = 'Indirect',
            LastName = 'Signer',
            Email = 'indirect.signer@example.com',
            AccountId = primaryAccount.Id
        );
        insert new List<Contact>{ directSigner, indirectSigner };

        if (!Schema.getGlobalDescribe().containsKey('AccountContactRelation')) {
            return;
        }
        SObject relation = Schema.getGlobalDescribe().get('AccountContactRelation').newSObject();
        relation.put('AccountId', relatedAccount.Id);
        relation.put('ContactId', indirectSigner.Id);
        insert relation;

        List<ESignatureSendController.SignerContactDTO> contacts =
            ESignatureSendController.getSignerContacts(String.valueOf(relatedAccount.Id), 'relationship-refresh');
        Map<String, ESignatureSendController.SignerContactDTO> contactsByEmail =
            new Map<String, ESignatureSendController.SignerContactDTO>();
        for (ESignatureSendController.SignerContactDTO contact : contacts) {
            contactsByEmail.put(contact.email, contact);
        }

        System.assert(contactsByEmail.containsKey('direct.signer@example.com'), 'Direct account contacts should remain available.');
        System.assert(contactsByEmail.containsKey('indirect.signer@example.com'), 'Indirect Account Contact Relationship contacts should be available.');
        System.assertEquals(String.valueOf(relatedAccount.Id), contactsByEmail.get('indirect.signer@example.com').accountId);
    }

    @IsTest
    static void sendEnvelopeUpdatesDraftAndCachesSourcePdf() {
        DraftFixture fixture = createDraftFixture();

        Test.startTest();
        ESignatureSendController.SendResultDTO result = ESignatureSendController.sendEnvelope(
            String.valueOf(fixture.envelope.Id),
            'Derek Hawley',
            'signer@example.com',
            'President',
            30,
            'Please review the attached proposal before signing.',
            'Commercial Cleaning Proposal Signature'
        );
        Test.stopTest();

        System.assertEquals(String.valueOf(fixture.envelope.Id), result.envelopeId);
        System.assertEquals('Sent', result.status);
        System.assert(result.signingUrl.contains('/ESignaturePage?t='), 'Result should include a public signing URL.');

        ESignature_Envelope__c env = [
            SELECT Status__c, Signer_Name__c, Signer_Email__c, Signer_Title__c,
                   Sent_At__c, Expires_At__c, Public_Signing_URL__c,
                   Request_Message__c, Request_Subject__c,
                   Source_File_Title__c, Source_ContentVersion_Id__c, Source_ContentDocument_Id__c
            FROM ESignature_Envelope__c
            WHERE Id = :fixture.envelope.Id
        ];
        System.assertEquals('Sent', env.Status__c);
        System.assertEquals('Derek Hawley', env.Signer_Name__c);
        System.assertEquals('signer@example.com', env.Signer_Email__c);
        System.assertEquals('President', env.Signer_Title__c);
        System.assertEquals('Please review the attached proposal before signing.', env.Request_Message__c);
        System.assertEquals('Commercial Cleaning Proposal Signature', env.Request_Subject__c);
        System.assertNotEquals(null, env.Sent_At__c);
        System.assertNotEquals(null, env.Expires_At__c);
        System.assertNotEquals(null, env.Public_Signing_URL__c);
        System.assertEquals('Send Controller Source', env.Source_File_Title__c);
        System.assertEquals(fixture.field.Content_Version_Id__c, env.Source_ContentVersion_Id__c);
        System.assertEquals(fixture.field.Content_Document_Id__c, env.Source_ContentDocument_Id__c);
        Id sourceVersionId = ESignatureUtil.safeId(fixture.field.Content_Version_Id__c);
        ContentVersion sourceStatus = [
            SELECT ESignature_Status__c
            FROM ContentVersion
            WHERE Id = :sourceVersionId
        ];
        System.assertEquals('Sent', sourceStatus.ESignature_Status__c, 'Sending should stamp the source file status.');

        System.assertEquals(1, [
            SELECT COUNT()
            FROM ESignature_Source_Chunk__c
            WHERE Envelope__c = :fixture.envelope.Id
        ], 'Source PDF should be cached for public signing.');
        System.assertEquals(1, [
            SELECT COUNT()
            FROM ESignature_Audit_Event__c
            WHERE Envelope__c = :fixture.envelope.Id
            AND Event_Type__c = 'Sent'
        ], 'Sent audit event should be written.');
        Task activity = [
            SELECT WhatId, OwnerId, Subject, Status, Description
            FROM Task
            WHERE WhatId = :fixture.parentId
            AND Subject = 'Email: Signature request sent'
            LIMIT 1
        ];
        System.assertEquals(fixture.parentId, activity.WhatId, 'Sender confirmation email should be logged to the parent record.');
        System.assertEquals(UserInfo.getUserId(), activity.OwnerId, 'Logged activity should belong to the Salesforce sender.');
        System.assertEquals('Completed', activity.Status, 'Logged activity should be completed.');
        System.assert(activity.Description.contains('Send Controller Source'), 'Logged activity should identify the document.');
        System.assert(activity.Description.contains('signer@example.com'), 'Logged activity should identify the signer.');
        EmailMessage emailLog = [
            SELECT RelatedToId, Subject, ToAddress, Incoming, Status, TextBody
            FROM EmailMessage
            WHERE RelatedToId = :fixture.parentId
            AND Subject = 'Signature request sent: Send Controller Source'
            LIMIT 1
        ];
        System.assertEquals(fixture.parentId, emailLog.RelatedToId, 'Sender confirmation should be logged as an email on the parent record.');
        System.assertEquals(UserInfo.getUserEmail(), emailLog.ToAddress, 'Email log should be addressed to the Salesforce sender.');
        System.assertEquals(false, emailLog.Incoming, 'Email log should be outbound.');
        System.assertEquals('3', emailLog.Status, 'Email log should be marked sent.');
        System.assert(emailLog.TextBody.contains('signer@example.com'), 'Email log should identify the signer.');
    }

    @IsTest
    static void sendEnvelopeCancelsPriorOpenEnvelopesForSameParent() {
        DraftFixture fixture = createDraftFixture();
        ContentVersion draftSource = createSourceFile('Prior Draft Source');
        ContentVersion sentSource = createSourceFile('Prior Sent Source');
        ContentVersion viewedSource = createSourceFile('Prior Viewed Source');

        Account otherParent = new Account(Name = 'Other Send Controller Parent');
        insert otherParent;
        ContentVersion otherSource = createSourceFile('Other Parent Source');

        ESignature_Envelope__c priorDraft = activeEnvelope(fixture.parentId, 'Draft', draftSource);
        ESignature_Envelope__c priorSent = activeEnvelope(fixture.parentId, 'Sent', sentSource);
        ESignature_Envelope__c priorViewed = activeEnvelope(fixture.parentId, 'Viewed', viewedSource);
        priorViewed.Parent_Record_Id__c = String.valueOf(fixture.parentId).substring(0, 15);
        ESignature_Envelope__c sameParentSigned = activeEnvelope(fixture.parentId, 'Signed', createSourceFile('Signed Source'));
        ESignature_Envelope__c otherParentSent = activeEnvelope(otherParent.Id, 'Sent', otherSource);
        insert new List<ESignature_Envelope__c>{ priorDraft, priorSent, priorViewed, sameParentSigned, otherParentSent };

        Test.startTest();
        ESignatureSendController.sendEnvelope(
            String.valueOf(fixture.envelope.Id),
            'Derek Hawley',
            'signer@example.com',
            'President',
            30,
            null,
            'Replacement Signature Request'
        );
        Test.stopTest();

        Map<Id, ESignature_Envelope__c> envelopes = new Map<Id, ESignature_Envelope__c>([
            SELECT Status__c, Cancellation_Reason__c
            FROM ESignature_Envelope__c
            WHERE Id IN :new Set<Id>{ fixture.envelope.Id, priorDraft.Id, priorSent.Id, priorViewed.Id, sameParentSigned.Id, otherParentSent.Id }
        ]);
        System.assertEquals('Sent', envelopes.get(fixture.envelope.Id).Status__c, 'The newly sent envelope should stay active.');
        System.assertEquals('Canceled', envelopes.get(priorDraft.Id).Status__c, 'Prior draft envelope on the same parent should be canceled.');
        System.assertEquals('Canceled', envelopes.get(priorSent.Id).Status__c, 'Prior sent envelope on the same parent should be canceled.');
        System.assertEquals('Canceled', envelopes.get(priorViewed.Id).Status__c, 'Prior viewed envelope on the same parent should be canceled.');
        System.assertEquals('Signed', envelopes.get(sameParentSigned.Id).Status__c, 'Completed envelopes should not be changed.');
        System.assertEquals('Sent', envelopes.get(otherParentSent.Id).Status__c, 'Open envelopes on other parent records should not be changed.');
        System.assertEquals('Envelope canceled because a newer e-signature envelope was sent for this record.', envelopes.get(priorDraft.Id).Cancellation_Reason__c);
        System.assertEquals('Envelope canceled because a newer e-signature envelope was sent for this record.', envelopes.get(priorSent.Id).Cancellation_Reason__c);
        System.assertEquals('Envelope canceled because a newer e-signature envelope was sent for this record.', envelopes.get(priorViewed.Id).Cancellation_Reason__c);

        Map<Id, ContentVersion> sources = new Map<Id, ContentVersion>([
            SELECT ESignature_Status__c
            FROM ContentVersion
            WHERE Id IN :new Set<Id>{
                ESignatureUtil.safeId(fixture.field.Content_Version_Id__c),
                draftSource.Id,
                sentSource.Id,
                viewedSource.Id,
                otherSource.Id
            }
        ]);
        System.assertEquals('Sent', sources.get(ESignatureUtil.safeId(fixture.field.Content_Version_Id__c)).ESignature_Status__c);
        System.assertEquals('Canceled', sources.get(draftSource.Id).ESignature_Status__c);
        System.assertEquals('Canceled', sources.get(sentSource.Id).ESignature_Status__c);
        System.assertEquals('Canceled', sources.get(viewedSource.Id).ESignature_Status__c);
        System.assertNotEquals('Canceled', sources.get(otherSource.Id).ESignature_Status__c);

        System.assertEquals(3, [
            SELECT COUNT()
            FROM ESignature_Audit_Event__c
            WHERE Envelope__c IN :new Set<Id>{ priorDraft.Id, priorSent.Id, priorViewed.Id }
            AND Event_Type__c = 'Canceled'
        ], 'Each automatically canceled envelope should receive a cancel audit event.');
    }

    @IsTest
    static void sendEnvelopeRejectsDraftWithoutFields() {
        Account parent = new Account(Name = 'Send Controller No Fields');
        insert parent;
        ESignature_Envelope__c env = new ESignature_Envelope__c(
            Status__c = 'Draft',
            Parent_Record_Id__c = String.valueOf(parent.Id),
            Parent_Object_Api_Name__c = 'Account'
        );
        insert env;

        try {
            ESignatureSendController.sendEnvelope(String.valueOf(env.Id), 'Derek Hawley', 'signer@example.com', null, 30, null, 'Missing Fields Subject');
            System.assert(false, 'Expected sendEnvelope to reject a draft without fields.');
        } catch (AuraHandledException ex) {
            System.assertNotEquals(null, ex.getMessage(), 'An AuraHandledException should be thrown.');
        }
    }

    @IsTest
    static void sendEnvelopeRequiresSubject() {
        DraftFixture fixture = createDraftFixture();

        try {
            ESignatureSendController.sendEnvelope(
                String.valueOf(fixture.envelope.Id),
                'Derek Hawley',
                'signer@example.com',
                'President',
                30,
                'Please review the attached proposal before signing.',
                '  '
            );
            System.assert(false, 'Expected sendEnvelope to reject a blank subject.');
        } catch (AuraHandledException ex) {
            System.assertNotEquals(null, ex.getMessage(), 'An AuraHandledException should be thrown.');
        }
    }

    @IsTest
    static void signatureRequestEmailUsesOriginalPackageFormat() {
        ESignature_Envelope__c env = new ESignature_Envelope__c(
            Signer_Name__c = 'Derek Hawley',
            Expires_At__c = Datetime.newInstance(2026, 7, 27, 12, 0, 0)
        );

        String html = ESignatureSendController.buildSignatureRequestEmailHtml(
            env,
            'https://example.com/signatures/apex/ESignaturePage?t=abc123',
            'Special Services Agreement',
            'Please review the revised scope.\nCall me with any questions.'
        );

        System.assert(html.contains('<table role="presentation" width="100%"'), 'Email should use the original table-based shell.');
        System.assert(html.contains('/resource/Kaizon_Solutions_Logo'), 'Email should render the configured company logo.');
        System.assert(html.contains('alt="Kaizon Solutions"'), 'Email logo should include accessible alt text.');
        System.assert(html.contains('has sent you a document that requires your signature'), 'Email should include the original request language.');
        System.assert(html.contains('Special Services Agreement'), 'Email should include the document title block.');
        System.assert(html.contains('Please review the revised scope.<br/>Call me with any questions.'), 'Email should include the sender-entered request message with line breaks preserved.');
        System.assert(!html.contains('Please review and sign the agreement.'), 'Custom messages should replace the generic request message.');
        System.assert(html.contains('Review &amp; Sign Document'), 'Email should include the original call-to-action label.');
        System.assert(html.contains('This link is unique to you and will expire on'), 'Email should include the expiration notice.');
        System.assert(html.contains('https://example.com/signatures/apex/ESignaturePage?t=abc123'), 'Email should include the fallback signing URL.');
        System.assert(html.contains('/services/apexrest/ESignature/v1/email-open?t=abc123'), 'Email should include the hidden email-open tracking pixel.');

        String defaultHtml = ESignatureSendController.buildSignatureRequestEmailHtml(
            env,
            'https://example.com/signatures/apex/ESignaturePage?t=abc123',
            'Special Services Agreement'
        );
        System.assert(defaultHtml.contains('Please review and sign the agreement.'), 'Blank custom messages should fall back to the default request message.');
    }

    @IsTest
    static void sentConfirmationEmailUsesEditableTemplateFormat() {
        Account parent = new Account(Name = 'Sent Confirmation Parent');
        insert parent;

        ESignature_Envelope__c env = new ESignature_Envelope__c(
            Signer_Name__c = 'Derek Hawley',
            Signer_Email__c = 'signer@example.com',
            Expires_At__c = Datetime.newInstance(2026, 7, 27, 12, 0, 0),
            Parent_Record_Id__c = String.valueOf(parent.Id),
            Parent_Object_Api_Name__c = 'Account'
        );

        String html = ESignatureSendController.buildSalesforceUserSentConfirmationEmailHtml(
            env,
            'https://example.com/signatures/apex/ESignaturePage?t=abc123',
            'Special Services Agreement'
        );

        System.assert(html.contains('<table role="presentation" width="100%"'), 'Sender confirmation email should use the branded shell.');
        System.assert(html.contains('/resource/Kaizon_Solutions_Logo'), 'Sender confirmation email should render the configured company logo.');
        System.assert(html.contains('The signature request was sent.'), 'Sender confirmation email should confirm the send action.');
        System.assert(html.contains('Special Services Agreement'), 'Sender confirmation email should include the document title.');
        System.assert(html.contains('Derek Hawley'), 'Sender confirmation email should include the signer name.');
        System.assert(html.contains('signer@example.com'), 'Sender confirmation email should include the signer email.');
        System.assert(html.contains('Status:</strong> Sent') || html.contains('Status: Sent'), 'Sender confirmation email should include sent status.');
        System.assert(html.contains(String.valueOf(parent.Id)), 'Sender confirmation email should include the envelope parent record id.');
        System.assert(html.contains('href="https://'), 'Sender confirmation record link should use an absolute Salesforce URL.');
        System.assert(html.contains('/lightning/r/Account/' + String.valueOf(parent.Id) + '/view'), 'Sender confirmation record link should point to the Lightning parent record route.');
        System.assert(!html.contains('/lightning/r/EmailMessage/'), 'Sender confirmation record link should not be relative to the EmailMessage route.');
        System.assert(!html.contains('{!Opportunity.Id}'), 'Sender confirmation email should not use an Opportunity-only merge field.');
    }

    private static DraftFixture createDraftFixture() {
        Account parent = new Account(Name = 'Send Controller Parent');
        insert parent;

        ESignature_Envelope__c env = new ESignature_Envelope__c(
            Status__c = 'Draft',
            Parent_Record_Id__c = String.valueOf(parent.Id),
            Parent_Object_Api_Name__c = 'Account'
        );
        insert env;

        ContentVersion source = new ContentVersion(
            Title = 'Send Controller Source',
            PathOnClient = 'Send Controller Source.pdf',
            VersionData = Blob.valueOf('%PDF-1.4\n%source\n%%EOF'),
            ESignature_File__c = true
        );
        insert source;
        source = [SELECT Id, ContentDocumentId FROM ContentVersion WHERE Id = :source.Id];

        ESignature_Field__c field = new ESignature_Field__c(
            Envelope__c = env.Id,
            Parent_Record_Id__c = String.valueOf(parent.Id),
            Content_Version_Id__c = String.valueOf(source.Id),
            Content_Document_Id__c = String.valueOf(source.ContentDocumentId),
            Field_Type__c = 'Signature',
            Label__c = 'Signature',
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
        insert field;

        DraftFixture fixture = new DraftFixture();
        fixture.parentId = parent.Id;
        fixture.envelope = env;
        fixture.field = field;
        return fixture;
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

    private static ESignature_Envelope__c activeEnvelope(Id parentId, String status, ContentVersion source) {
        return new ESignature_Envelope__c(
            Status__c = status,
            Parent_Record_Id__c = String.valueOf(parentId),
            Parent_Object_Api_Name__c = 'Account',
            Signer_Email__c = 'prior@example.com',
            Source_ContentVersion_Id__c = String.valueOf(source.Id),
            Source_ContentDocument_Id__c = String.valueOf(source.ContentDocumentId)
        );
    }
}
