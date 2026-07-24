@IsTest
private class ESignatureUtilTest {
    @IsTest
    static void estimatePageCountRecognizesCompactAndWhitespaceMarkers() {
        Blob pdfBlob = Blob.valueOf(
            '%PDF-1.4\n' +
            '1 0 obj << /Type/Pages /Count 3 >> endobj\n' +
            '2 0 obj << /Type/Page /Parent 1 0 R >> endobj\n' +
            '3 0 obj << /Type /Page /Parent 1 0 R >> endobj\n' +
            '4 0 obj << /Type\n/Page /Parent 1 0 R >> endobj\n' +
            '%%EOF'
        );

        System.assertEquals('3', ESignatureUtil.estimatePageCount(pdfBlob));
    }

    @IsTest
    static void estimatePageCountFallsBackToOneWhenNoPageMarkersExist() {
        Blob pdfBlob = Blob.valueOf('%PDF-1.4\n1 0 obj << /Type/Pages /Count 0 >> endobj\n%%EOF');

        System.assertEquals('1', ESignatureUtil.estimatePageCount(pdfBlob));
    }

    @IsTest
    static void getEnvelopeTitlePrefersStoredSourceContentVersionTitle() {
        ESignature_Envelope__c env = new ESignature_Envelope__c(
            Source_File_Title__c = 'Content Version Record Title'
        );

        System.assertEquals('Content Version Record Title', ESignatureUtil.getEnvelopeTitle(env));
    }

    @IsTest
    static void stampEnvelopeParentSetsCaseLookup() {
        Case parent = new Case(
            Subject = 'Case Parent',
            Status = 'New',
            Origin = 'Phone'
        );
        insert parent;

        ESignature_Envelope__c env = new ESignature_Envelope__c();
        ESignatureUtil.stampEnvelopeParent(env, String.valueOf(parent.Id));

        System.assertEquals(String.valueOf(parent.Id), env.Parent_Record_Id__c);
        System.assertEquals('Case', env.Parent_Object_Api_Name__c);
        System.assertEquals(parent.Id, env.Case__c);
        System.assertEquals(null, env.Account__c);
        System.assertEquals(null, env.Opportunity__c);
        System.assertEquals(null, env.Work_Order__c);
    }

    @IsTest
    static void parentRecordNameResolvesOpportunityName() {
        Opportunity parent = new Opportunity(
            Name = 'Record Name Token Opportunity',
            StageName = 'Prospecting',
            CloseDate = Date.today().addDays(30)
        );
        insert parent;

        System.assertEquals(
            'Record Name Token Opportunity',
            ESignatureUtil.parentRecordName(String.valueOf(parent.Id), 'Opportunity')
        );
    }

    @IsTest
    static void sourceFileHelpersCacheAndStampStatus() {
        Account parent = new Account(Name = 'Util Source Parent');
        insert parent;
        ContentVersion source = new ContentVersion(
            Title = 'Utility Source PDF',
            PathOnClient = 'Utility Source PDF.pdf',
            VersionData = Blob.valueOf('%PDF-1.4\n%source\n%%EOF'),
            FirstPublishLocationId = parent.Id,
            ESignature_File__c = true
        );
        insert source;
        source = [SELECT Id, ContentDocumentId, Title FROM ContentVersion WHERE Id = :source.Id];

        ESignature_Envelope__c env = new ESignature_Envelope__c(
            Status__c = 'Draft',
            Parent_Record_Id__c = String.valueOf(parent.Id)
        );
        insert env;
        insert new ESignature_Field__c(
            Envelope__c = env.Id,
            Parent_Record_Id__c = String.valueOf(parent.Id),
            Content_Version_Id__c = String.valueOf(source.Id),
            Content_Document_Id__c = String.valueOf(source.ContentDocumentId),
            Field_Type__c = 'Signature',
            Label__c = 'Signature',
            Page_Number__c = 1,
            Required__c = true,
            Sequence__c = 1
        );

        System.assertEquals(source.Id, ESignatureUtil.getEnvelopeSourceVersionId(env.Id));
        System.assertEquals(source.ContentDocumentId, ESignatureUtil.getEnvelopeSourceDocumentId(env.Id));
        System.assertEquals(source.Id, ESignatureUtil.getContentVersionById(source.Id, false).Id);
        System.assertEquals(source.Id, ESignatureUtil.getContentVersionById(source.Id, true).Id);
        System.assertEquals(source.Id, ESignatureUtil.getLatestContentVersion(source.ContentDocumentId, false).Id);
        System.assertEquals(source.Id, ESignatureUtil.getLatestSourceVersion(new ESignature_Envelope__c(Id = env.Id), false).Id);

        Map<Id, Id> sourceByEnvelope = ESignatureUtil.getSourceDocumentIdsByEnvelopeId(new Set<Id>{ env.Id });
        System.assertEquals(source.ContentDocumentId, sourceByEnvelope.get(env.Id));
        Map<Id, String> titleByDocument = ESignatureUtil.getContentDocumentTitles(new Set<Id>{ source.ContentDocumentId });
        System.assertEquals('Utility Source PDF', titleByDocument.get(source.ContentDocumentId));
        System.assertEquals('Utility Source PDF', ESignatureUtil.getEnvelopeTitle(new ESignature_Envelope__c(Id = env.Id)));

        ESignatureUtil.cacheSourcePdfForEnvelope(env.Id);
        System.assert(ESignatureUtil.getCachedSourcePdfBlob(env.Id).toString().contains('%source'));

        ESignatureUtil.updateSourceFileESignatureStatus(new ESignature_Envelope__c(Id = env.Id), 'Sent');
        source = [SELECT ESignature_Status__c FROM ContentVersion WHERE Id = :source.Id];
        System.assertEquals('Sent', source.ESignature_Status__c);

        ESignatureUtil.audit(env.Id, 'Sent', UserInfo.getUserEmail(), 'Utility audit event.');
        System.assertEquals(1, [
            SELECT COUNT()
            FROM ESignature_Audit_Event__c
            WHERE Envelope__c = :env.Id
            AND Event_Type__c = 'Sent'
        ]);
    }

    @IsTest
    static void tokenUrlAndPrimitiveHelpersHandleCommonValues() {
        String token = ESignatureUtil.generateToken();
        System.assert(String.isNotBlank(token));
        String tokenHash = ESignatureUtil.hashToken(token);
        System.assertEquals(64, tokenHash.length());

        ESignature_Envelope__c env = new ESignature_Envelope__c(
            Secure_Token_Hash__c = tokenHash,
            Signer_Email__c = 'signer@example.com'
        );
        insert env;
        System.assertEquals(env.Id, ESignatureUtil.findEnvelopeByToken(token).Id);

        System.assertEquals(12, ESignatureUtil.intValue('12', 0));
        System.assertEquals(4.5, ESignatureUtil.decimalValue('4.5', 0));
        System.assertEquals(true, ESignatureUtil.boolValue('yes', false));
        System.assertEquals(false, ESignatureUtil.boolValue('no', true));
        System.assertEquals('abc', ESignatureUtil.stringValue('abc'));
        System.assertEquals('&lt;abc&gt;', ESignatureUtil.escapeHtml('<abc>'));
        System.assertEquals('fallback', ESignatureUtil.firstNonBlank(new List<String>{ null, '', 'fallback' }));

        Account parent = new Account(Name = 'Util Id Parent');
        insert parent;
        System.assertEquals(parent.Id, ESignatureUtil.safeId(String.valueOf(parent.Id)));
        System.assertEquals(null, ESignatureUtil.safeId('not-an-id'));

        System.assertEquals('https://example.com/signatures', ESignatureUtil.normalizeBaseUrl('https://example.com/signatures/'));
        System.assertEquals(
            'https://example.com/signatures',
            ESignatureUtil.siteRootUrl('https://example.com/signatures/apex/ESignaturePage')
        );
        System.assertEquals('https://example.com/signatures/apex', ESignatureUtil.siteApexUrl('https://example.com/signatures'));
        System.assert(ESignatureUtil.buildPdfResourceUrl('abc 123').contains('abc'));
        System.assert(ESignatureUtil.buildPdfResourceUrl('abc 123').contains('123'));

        ESignature_Setting__mdt settings = ESignatureUtil.getSettings();
        System.assert(String.isNotBlank(ESignatureUtil.buildFinalizerCallbackUrl(settings)));
        if (!String.isBlank(settings.Site_Base_URL__c)) {
            System.assert(ESignatureUtil.buildSigningUrl('abc').contains('/ESignaturePage?t=abc'));
        }

        Map<String, Object> payload = new Map<String, Object>();
        ESignatureUtil.addCurrentRequestContext(payload);
        System.assert(payload.containsKey('serverTimestamp'));

        Test.startTest();
        ESignatureUtil.publishSignerCommand('Viewed', env, token, payload, false);
        Test.stopTest();
    }

    @IsTest
    static void configuredOrgWideEmailAddressPrefersExplicitSetting() {
        ESignature_Setting__mdt settings = new ESignature_Setting__mdt(
            Org_Wide_Email_Address__c = 'orgwide@example.com',
            Org_Wide_Email_Address_Id__c = '0D2TS0000000k1F0AQ',
            Default_From_Email__c = 'default@example.com',
            Email_Logo_URL__c = 'https://example.com/logo.png',
            Include_User_Email_Signature__c = true
        );
        System.assertEquals('orgwide@example.com', ESignatureUtil.configuredOrgWideEmailAddress(settings));
        System.assertEquals((Id) '0D2TS0000000k1F0AQ', ESignatureUtil.configuredOrgWideEmailAddressId(settings));
        System.assertEquals('https://example.com/logo.png', ESignatureUtil.configuredEmailLogoUrl(settings));
        System.assertEquals(true, ESignatureUtil.includeUserEmailSignature(settings));
        String logoHtml = ESignatureUtil.emailLogoHtml();
        System.assert(logoHtml.contains('width="252"'), 'Email logo should render at its native width.');
        System.assert(logoHtml.contains('height="73"'), 'Email logo should render at its native height.');

        settings.Org_Wide_Email_Address__c = null;
        settings.Org_Wide_Email_Address_Id__c = 'not-an-id';
        settings.Include_User_Email_Signature__c = false;
        System.assertEquals('default@example.com', ESignatureUtil.configuredOrgWideEmailAddress(settings));
        System.assertEquals(null, ESignatureUtil.configuredOrgWideEmailAddressId(settings));
        System.assertEquals(false, ESignatureUtil.includeUserEmailSignature(settings));
    }
}
