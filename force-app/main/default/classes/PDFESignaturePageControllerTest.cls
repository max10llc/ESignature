@IsTest
private class PDFESignaturePageControllerTest {
    @IsTest
    static void signBlocksWhenRequiredFieldIsMissing() {
        String token = 'page-required-field-token';
        ESignature_Envelope__c env = createEnvelope(token, 'Viewed');
        insertRequiredField(env.Id, 'Required Text');
        setSigningPageToken(token);

        PDFESignaturePageController controller = new PDFESignaturePageController();
        controller.continueAfterDisclosure();
        controller.typedName = 'Derek Hawley';
        controller.signerTitle = 'President';
        controller.signerFieldsJson = '[]';

        controller.sign();

        System.assertEquals(false, controller.submitted, 'Signer should not be submitted when a required field is blank.');
        System.assert(hasMessageContaining('Required Text'), 'The page should name the missing required field.');
    }

    @IsTest
    static void signPublishesWhenRequiredFieldsAreSubmitted() {
        String token = 'page-complete-field-token';
        ESignature_Envelope__c env = createEnvelope(token, 'Viewed');
        ESignature_Field__c field = insertRequiredField(env.Id, 'Required Text');
        setSigningPageToken(token);

        PDFESignaturePageController controller = new PDFESignaturePageController();
        System.assertEquals(true, controller.getCanSign(), 'Envelope should be available for signing.');
        System.assert(controller.getFieldsJson().contains('Required Text'), 'Prepared fields should be exposed to the page.');

        controller.continueAfterDisclosure();
        controller.typedName = 'Derek Hawley';
        controller.signerTitle = 'President';
        controller.signerFieldsJson = JSON.serialize(new List<Object>{
            new Map<String, Object>{ 'id' => String.valueOf(field.Id), 'value' => 'Completed value' }
        });

        Test.startTest();
        controller.sign();
        Test.stopTest();

        System.assertEquals(true, controller.submitted, 'Signer should be submitted when required fields are complete.');
        System.assertEquals('The document is complete and will be emailed to you shortly.', controller.pageMessage);
    }

    @IsTest
    static void disclosureDeclinePublishesDeclinedCommand() {
        String token = 'page-disclosure-decline-token';
        createEnvelope(token, 'Viewed');
        setSigningPageToken(token);

        PDFESignaturePageController controller = new PDFESignaturePageController();

        Test.startTest();
        controller.declineDisclosure();
        Test.stopTest();

        System.assertEquals(true, controller.submitted, 'Declining the disclosure should submit the decline action.');
        System.assertEquals('This signature request has been declined.', controller.pageMessage);
    }

    @IsTest
    static void declineRequiresReasonAndDisclosureConfirmation() {
        String token = 'page-decline-prompt-token';
        createEnvelope(token, 'Viewed');
        setSigningPageToken(token);

        PDFESignaturePageController controller = new PDFESignaturePageController();

        controller.decline();
        System.assertEquals(false, controller.submitted, 'Decline should not submit without a reason.');
        System.assert(hasMessageContaining('Please provide a reason'), 'Decline should require a reason.');

        controller.declineReason = 'I do not agree with the terms.';
        controller.decline();
        System.assertEquals(false, controller.submitted, 'Decline should not submit without disclosure confirmation.');
        System.assert(hasMessageContaining('confirm the disclosure'), 'Decline should require disclosure confirmation.');

        controller.declineTermsAccepted = true;

        Test.startTest();
        controller.decline();
        Test.stopTest();

        System.assertEquals(true, controller.submitted, 'Decline should submit after reason and disclosure confirmation.');
        System.assertEquals('This signature request has been declined.', controller.pageMessage);
    }

    @IsTest
    static void delegateRequiresFieldsAndDisclosureConfirmation() {
        String token = 'page-delegate-required-token';
        createEnvelope(token, 'Viewed');
        setSigningPageToken(token);

        PDFESignaturePageController controller = new PDFESignaturePageController();

        controller.delegateAgreement();
        System.assertEquals(false, controller.submitted, 'Delegate should not submit without an email.');
        System.assert(hasMessageContaining('Delegate email is required'), 'Delegate should require an email.');

        controller.delegateEmail = 'not-an-email';
        controller.delegateName = 'Delegate Signer';
        controller.delegateMessage = 'Please sign this for me.';
        controller.delegateTermsAccepted = true;
        controller.delegateAgreement();

        System.assertEquals(false, controller.submitted, 'Delegate should not submit with an invalid email.');
        System.assert(hasMessageContaining('valid delegate email'), 'Delegate should validate the email address.');
    }

    @IsTest
    static void delegatePublishesCommandWhenValid() {
        String token = 'page-delegate-valid-token';
        createEnvelope(token, 'Viewed');
        setSigningPageToken(token);

        PDFESignaturePageController controller = new PDFESignaturePageController();
        controller.delegateEmail = 'delegate@example.com';
        controller.delegateName = 'Delegate Signer';
        controller.delegateMessage = 'Please sign this for me.';
        controller.delegateTermsAccepted = true;

        Test.startTest();
        controller.delegateAgreement();
        Test.stopTest();

        System.assertEquals(true, controller.submitted, 'Delegate should submit after all required values are provided.');
        System.assertEquals('This signature request has been delegated to delegate@example.com.', controller.pageMessage);
    }

    @IsTest
    static void invalidTokenShowsError() {
        setSigningPageToken('not-a-real-token');

        PDFESignaturePageController controller = new PDFESignaturePageController();

        System.assertEquals(true, controller.hasError, 'Invalid token should show an error.');
        System.assertEquals(false, controller.getCanSign(), 'Invalid token should not be signable.');
        System.assertEquals('', controller.getSignerLabel(), 'Missing envelope should not render a signer label.');
        System.assertEquals('[]', controller.getFieldsJson(), 'Missing envelope should not render field JSON.');
    }

    @IsTest
    static void expiredTokenShowsErrorOnInitialize() {
        String token = 'page-expired-token';
        ESignature_Envelope__c env = createEnvelope(token, 'Sent');
        env.Expires_At__c = System.now().addMinutes(-5);
        update env;
        setSigningPageToken(token);

        PDFESignaturePageController controller = new PDFESignaturePageController();
        controller.initializePage();

        System.assertEquals(true, controller.hasError, 'Expired token should show an error.');
        System.assertEquals('This signing link has expired.', controller.pageMessage);
        System.assertEquals(false, controller.getCanSign(), 'Expired token should not be signable.');
    }

    @IsTest
    static void signedEnvelopeShowsSubmittedMessage() {
        String token = 'page-already-signed-token';
        createEnvelope(token, 'Signed');
        setSigningPageToken(token);

        PDFESignaturePageController controller = new PDFESignaturePageController();

        System.assertEquals(true, controller.submitted, 'Already signed envelope should render as submitted.');
        System.assertEquals('This document has already been completed.', controller.pageMessage);
        System.assertEquals(false, controller.getCanSign(), 'Already signed envelope should not be signable.');
    }

    @IsTest
    static void signedEnvelopeInErrorStatusShowsCompletedMessage() {
        String token = 'page-signed-error-token';
        ESignature_Envelope__c env = createEnvelope(token, 'Error');
        env.Signed_At__c = System.now();
        update env;
        setSigningPageToken(token);

        PDFESignaturePageController controller = new PDFESignaturePageController();

        System.assertEquals(true, controller.submitted, 'Signed envelopes should stay closed even if finalization is in Error.');
        System.assertEquals('This document has already been completed.', controller.pageMessage);
        System.assertEquals(false, controller.getCanSign(), 'Signed envelopes should not become signable again after finalization errors.');
    }

    @IsTest
    static void completedEnvelopeStatusShowsSubmittedMessage() {
        String token = 'page-completed-status-token';
        createEnvelope(token, 'Completed');
        setSigningPageToken(token);

        PDFESignaturePageController controller = new PDFESignaturePageController();

        System.assertEquals(true, controller.submitted, 'Completed envelopes should render as submitted.');
        System.assertEquals('This document has already been completed.', controller.pageMessage);
        System.assertEquals(false, controller.getCanSign(), 'Completed envelopes should not be signable.');
    }

    @IsTest
    static void cancelledEnvelopeStatusShowsCancelledMessage() {
        assertCancelledEnvelopeStatus('Canceled', 'page-canceled-status-token');
        assertCancelledEnvelopeStatus('Cancelled', 'page-cancelled-status-token');
    }

    @IsTest
    static void legacyDeclinedStatusShowsDeclinedMessage() {
        String token = 'page-legacy-declined-token';
        ESignature_Envelope__c env = createEnvelope(token, null);
        env.Status__c = 'Declined';
        update env;
        setSigningPageToken(token);

        PDFESignaturePageController controller = new PDFESignaturePageController();

        System.assertEquals(true, controller.submitted, 'Legacy declined envelopes should render as submitted.');
        System.assertEquals('This document has already been declined.', controller.pageMessage);
        System.assertEquals(false, controller.getCanSign(), 'Legacy declined envelopes should not be signable.');
    }

    @IsTest
    static void declineReasonWithoutDeclinedStatusShowsDeclinedMessage() {
        String token = 'page-decline-reason-token';
        ESignature_Envelope__c env = createEnvelope(token, 'Viewed');
        env.Decline_Reason__c = 'Signer declined from prompt.';
        update env;
        setSigningPageToken(token);

        PDFESignaturePageController controller = new PDFESignaturePageController();

        System.assertEquals(true, controller.submitted, 'Envelope with a decline reason should render as declined.');
        System.assertEquals('This document has already been declined.', controller.pageMessage);
        System.assertEquals(false, controller.getCanSign(), 'Envelope with a decline reason should not be signable.');
    }

    @IsTest
    static void downloadFileNameUsesSourceContentVersionTitle() {
        String token = 'page-download-title-token';
        ESignature_Envelope__c env = createEnvelope(token, 'Viewed');
        env.Source_File_Title__c = 'Customer Agreement Final';
        update env;
        setSigningPageToken(token);

        PDFESignaturePageController controller = new PDFESignaturePageController();

        System.assertEquals('Customer Agreement Final.pdf', controller.getDocumentDownloadFileName());
        System.assertEquals('Customer Agreement Final', controller.getDocumentTitle());
    }

    @IsTest
    static void senderPanelUsesEnvelopeSenderAndDefaultMessage() {
        String token = 'page-sender-panel-token';
        ESignature_Envelope__c env = createEnvelope(token, 'Viewed');
        env.Sender_User__c = UserInfo.getUserId();
        update env;
        setSigningPageToken(token);

        PDFESignaturePageController controller = new PDFESignaturePageController();

        System.assertEquals(UserInfo.getName(), controller.getSenderDisplayName(), 'Sender panel should show the Salesforce user who sent the envelope.');
        System.assert(controller.getSignerIntroText().contains(UserInfo.getName()), 'Intro text should include the sender name.');
        System.assertEquals('Please review and sign the agreement.', controller.getEnvelopeMessage());
    }

    @IsTest
    static void signUsesEnvelopeSignerNameWithoutSignerInput() {
        String token = 'page-basic-validation-token';
        createEnvelope(token, 'Viewed');
        setSigningPageToken(token);

        PDFESignaturePageController controller = new PDFESignaturePageController();
        controller.sign();
        System.assert(hasMessageContaining('agree to sign electronically'), 'Consent should be required first.');

        controller.continueAfterDisclosure();
        controller.typedName = '';
        controller.signerTitle = 'President';
        controller.signerFieldsJson = '[]';

        Test.startTest();
        controller.sign();
        Test.stopTest();

        System.assertEquals(true, controller.submitted, 'Signer should not need to type their legal name on the page.');
        System.assertEquals('Derek Hawley', controller.typedName, 'The envelope signer name should be used for the signature payload.');
    }

    @IsTest
    static void signAcceptsTitleFromSubmittedPdfField() {
        String token = 'page-title-field-token';
        ESignature_Envelope__c env = createEnvelope(token, 'Viewed');
        ESignature_Field__c field = insertRequiredTitleField(env.Id, 'Signer Title');
        setSigningPageToken(token);

        PDFESignaturePageController controller = new PDFESignaturePageController();
        controller.continueAfterDisclosure();
        controller.typedName = 'Derek Hawley';
        controller.signerTitle = '';
        controller.signerFieldsJson = JSON.serialize(new List<Object>{
            new Map<String, Object>{ 'id' => String.valueOf(field.Id), 'value' => 'Vice President' }
        });

        Test.startTest();
        controller.sign();
        Test.stopTest();

        System.assertEquals(true, controller.submitted, 'Signer title can be supplied by the Title field on the PDF.');
    }

    private static ESignature_Envelope__c createEnvelope(String token, String status) {
        ESignature_Envelope__c env = new ESignature_Envelope__c(
            Envelope_Status__c = status,
            Secure_Token_Hash__c = PDFESignatureUtil.hashToken(token),
            Signer_Name__c = 'Derek Hawley',
            Signer_Email__c = 'signer@example.com',
            Signer_Title__c = 'President',
            Parent_Object_Api_Name__c = 'Opportunity'
        );
        insert env;
        return env;
    }

    private static void assertCancelledEnvelopeStatus(String status, String token) {
        createEnvelope(token, status);
        setSigningPageToken(token);

        PDFESignaturePageController controller = new PDFESignaturePageController();

        System.assertEquals(true, controller.submitted, status + ' envelopes should render as submitted.');
        System.assertEquals('This document has already been cancelled.', controller.pageMessage);
        System.assertEquals(false, controller.getCanSign(), status + ' envelopes should not be signable.');
    }

    private static ESignature_Field__c insertRequiredField(Id envelopeId, String label) {
        ESignature_Field__c field = new ESignature_Field__c(
            Envelope__c = envelopeId,
            Field_Type__c = 'Text',
            Label__c = label,
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
        return field;
    }

    private static ESignature_Field__c insertRequiredTitleField(Id envelopeId, String label) {
        ESignature_Field__c field = insertRequiredField(envelopeId, label);
        field.Field_Type__c = 'Title';
        update field;
        return field;
    }

    private static void setSigningPageToken(String token) {
        Test.setCurrentPage(Page.PDFESignaturePage);
        ApexPages.currentPage().getParameters().put('t', token);
    }

    private static Boolean hasMessageContaining(String expected) {
        for (ApexPages.Message message : ApexPages.getMessages()) {
            if (message.getSummary() != null && message.getSummary().contains(expected)) {
                return true;
            }
        }
        return false;
    }
}
