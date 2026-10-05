public without sharing class ESignaturePageController {
    public String token { get; private set; }
    public ESignature_Envelope__c envelope { get; private set; }
    public String typedName { get; set; }
    public String signerTitle { get; set; }
    public String signatureImageDataUrl { get; set; }
    public String initialsImageDataUrl { get; set; }
    public String signerFieldsJson { get; set; }
    public Boolean consent { get; set; }
    public Boolean disclosureAccepted { get; set; }
    public String declineReason { get; set; }
    public Boolean declineTermsAccepted { get; set; }
    public String delegateEmail { get; set; }
    public String delegateName { get; set; }
    public String delegateMessage { get; set; }
    public Boolean delegateTermsAccepted { get; set; }
    public String pageMessage { get; private set; }
    public Boolean hasError { get; private set; }
    public Boolean submitted { get; private set; }

    public ESignaturePageController() {
        hasError = false;
        submitted = false;
        consent = false;
        disclosureAccepted = false;
        declineTermsAccepted = false;
        delegateTermsAccepted = false;
        token = ApexPages.currentPage().getParameters().get('t');
        loadEnvelope();
        if (envelope != null) {
            typedName = envelope.Signer_Name__c;
            signerTitle = envelope.Signer_Title__c;
        }
    }

    /**
     * Site Guest Users cannot update existing Salesforce records.  This method
     * only publishes a platform event command.  A platform-event trigger, running
     * outside the guest user's record edit restriction, records the Viewed state.
     */
    public PageReference initializePage() {
        if (envelope == null || hasError == true || submitted == true) {
            return null;
        }
        if (envelope.Expires_At__c != null && envelope.Expires_At__c < System.now()) {
            hasError = true;
            submitted = false;
            pageMessage = 'This signing link has expired.';
            publishCommand('Expired', new Map<String, Object>{
                'message' => 'Signing link expired when opened.'
            }, false);
            return null;
        }
        String status = normalizedEnvelopeStatus();
        if (status == 'sent' || status == 'viewed' || status == 'error') {
            publishCommand('Viewed', new Map<String, Object>{
                'message' => 'Signer opened the envelope.'
            }, false);
        }
        return null;
    }

    private void loadEnvelope() {
        hasError = false;
        submitted = false;
        envelope = ESignatureUtil.findEnvelopeByToken(token);
        if (envelope == null) {
            hasError = true;
            pageMessage = 'This signing link is invalid or no longer available.';
            return;
        }
        if (envelope.Expires_At__c != null && envelope.Expires_At__c < System.now()) {
            hasError = true;
            pageMessage = 'This signing link has expired.';
            return;
        }
        if (isCompletedEnvelope()) {
            submitted = true;
            pageMessage = 'This document has already been completed.';
            return;
        }
        if (isDeclinedEnvelope()) {
            submitted = true;
            pageMessage = 'This document has already been declined.';
            return;
        }
        if (isCancelledEnvelope()) {
            submitted = true;
            pageMessage = envelope.Cancellation_Reason__c == 'The source document was deleted from Salesforce.'
                ? 'This document is no longer available because the sender deleted it. Please contact the sender for a new signing request.'
                : 'This document has already been cancelled.';
            return;
        }
        if (normalizedEnvelopeStatus() == 'expired') {
            hasError = true;
            pageMessage = 'This signing link has expired.';
            return;
        }
        if (envelope.Signed_At__c != null || new Set<String>{ 'finalizing', 'signed', 'completed', 'complete' }.contains(normalizedEnvelopeStatus())) {
            if (normalizedEnvelopeStatus() == 'error') {
                hasError = true;
                pageMessage = 'Your signature was submitted, but the document could not be completed. Please contact the sender.';
            } else {
                submitted = true;
                pageMessage = 'Your signature has been submitted. The document is still being processed. You will receive an email when it is complete.';
            }
            return;
        }
    }

    public Boolean getCanSign() {
        return envelope != null && hasError != true && submitted != true &&
            envelope.Signed_At__c == null &&
            (normalizedEnvelopeStatus() == 'sent' || normalizedEnvelopeStatus() == 'viewed' || normalizedEnvelopeStatus() == 'error');
    }

    public String getTerminalTitle() {
        if (hasError == true) {
            return 'Document Unavailable';
        }
        if (String.isBlank(pageMessage)) {
            return 'Document Status';
        }
        String lowerMessage = pageMessage.toLowerCase();
        if (lowerMessage.contains('no longer available')) {
            return 'Document Unavailable';
        }
        if (lowerMessage.contains('still being processed')) {
            return 'Signature Submitted';
        }
        if (lowerMessage.contains('declin')) {
            return 'Document Declined';
        }
        if (lowerMessage.contains('cancel')) {
            return 'Document Cancelled';
        }
        if (lowerMessage.contains('delegated')) {
            return 'Document Delegated';
        }
        return 'Document Complete';
    }

    public String getDocumentTitle() {
        return ESignatureUtil.getEnvelopeTitle(envelope);
    }

    public String getDocumentDownloadFileName() {
        return pdfFileName(ESignatureUtil.getEnvelopeTitle(envelope));
    }

    public String getSignerLabel() {
        if (envelope == null) {
            return '';
        }
        return envelope.Signer_Name__c + ' (' + envelope.Signer_Email__c + ')';
    }

    public String getSenderDisplayName() {
        if (envelope == null || envelope.Id == null) {
            return '';
        }
        try {
            ESignature_Envelope__c senderEnvelope = [
                SELECT Sender_User__r.Name, CreatedBy.Name
                FROM ESignature_Envelope__c
                WHERE Id = :envelope.Id
                LIMIT 1
            ];
            if (senderEnvelope.Sender_User__r != null && !String.isBlank(senderEnvelope.Sender_User__r.Name)) {
                return senderEnvelope.Sender_User__r.Name;
            }
            if (senderEnvelope.CreatedBy != null && !String.isBlank(senderEnvelope.CreatedBy.Name)) {
                return senderEnvelope.CreatedBy.Name;
            }
        } catch (Exception ignore) {}
        return 'the sender';
    }

    public String getSignerIntroText() {
        return 'E-signature request from ' + getSenderDisplayName();
    }

    public String getEnvelopeMessage() {
        if (envelope != null && !String.isBlank(envelope.Request_Message__c)) {
            return envelope.Request_Message__c;
        }
        return 'Please review and sign the agreement.';
    }

    public String getPdfUrl() {
        return ESignatureUtil.buildPdfResourceUrl(token);
    }

    public String getFieldsJson() {
        if (envelope == null) {
            return '[]';
        }
        List<Object> output = new List<Object>();
        for (ESignature_Field__c field : [
            SELECT Id, Field_Type__c, Label__c, Page_Number__c, X_Percent__c, Y_Percent__c,
                   Width_Percent__c, Height_Percent__c, Required__c, Value__c, Completed__c
            FROM ESignature_Field__c
            WHERE Envelope__c = :envelope.Id
            ORDER BY Page_Number__c ASC, Sequence__c ASC, CreatedDate ASC
        ]) {
            Map<String, Object> row = new Map<String, Object>();
            row.put('id', field.Id);
            row.put('type', field.Field_Type__c);
            row.put('label', String.isBlank(field.Label__c) ? field.Field_Type__c : field.Label__c);
            row.put('pageNumber', field.Page_Number__c == null ? 1 : Integer.valueOf(field.Page_Number__c));
            row.put('xPercent', field.X_Percent__c);
            row.put('yPercent', field.Y_Percent__c);
            row.put('widthPercent', field.Width_Percent__c);
            row.put('heightPercent', field.Height_Percent__c);
            row.put('required', field.Required__c);
            row.put('value', field.Value__c);
            row.put('completed', field.Completed__c);
            output.add(row);
        }
        return JSON.serialize(output);
    }

    public PageReference sign() {
        // Re-read after a postback: the source may have been deleted while the
        // signer had the cached PDF open in their browser.
        loadEnvelope();
        if (!getCanSign()) {
            return null;
        }
        if (consent != true || disclosureAccepted != true) {
            ApexPages.addMessage(new ApexPages.Message(ApexPages.Severity.ERROR, 'You must agree to sign electronically.'));
            return null;
        }
        typedName = envelope == null ? null : envelope.Signer_Name__c;
        if (String.isBlank(typedName)) {
            ApexPages.addMessage(new ApexPages.Message(ApexPages.Severity.ERROR, 'The signer name is missing from this request.'));
            return null;
        }
        try {
            validateSubmittedFieldsOnly();
            String resolvedSignerTitle = String.isBlank(signerTitle) ? titleFromSubmittedFields(signerFieldsJson) : signerTitle.trim();
            Map<String, Object> payload = new Map<String, Object>();
            payload.put('typedName', typedName.trim());
            payload.put('signerTitle', resolvedSignerTitle);
            payload.put('signatureImageDataUrl', signatureImageDataUrl);
            payload.put('initialsImageDataUrl', initialsImageDataUrl);
            payload.put('signatureMethod', String.isBlank(signatureImageDataUrl) ? 'Typed' : 'Drawn');
            payload.put('signerFieldsJson', signerFieldsJson);
            payload.put('message', 'Signer completed required fields and submitted signature.');
            publishCommand('Signed', payload, true);
            submitted = true;
            pageMessage = 'Your signature has been submitted. The document is still being processed. You will receive an email when it is complete.';
        } catch (Exception e) {
            ApexPages.addMessage(new ApexPages.Message(ApexPages.Severity.ERROR, e.getMessage()));
        }
        return null;
    }

    public PageReference decline() {
        loadEnvelope();
        if (envelope == null || submitted == true) {
            return null;
        }
        if (String.isBlank(declineReason)) {
            ApexPages.addMessage(new ApexPages.Message(ApexPages.Severity.ERROR, 'Please provide a reason for declining this agreement.'));
            return null;
        }
        if (declineTermsAccepted != true) {
            ApexPages.addMessage(new ApexPages.Message(ApexPages.Severity.ERROR, 'You must confirm the disclosure before declining.'));
            return null;
        }
        try {
            String resolvedDeclineReason = declineReason.trim();
            Map<String, Object> payload = new Map<String, Object>();
            payload.put('declineReason', resolvedDeclineReason);
            payload.put('message', resolvedDeclineReason);
            publishCommand('Declined', payload, true);
            submitted = true;
            pageMessage = 'This signature request has been declined.';
        } catch (Exception e) {
            ApexPages.addMessage(new ApexPages.Message(ApexPages.Severity.ERROR, e.getMessage()));
        }
        return null;
    }

    public PageReference delegateAgreement() {
        loadEnvelope();
        if (envelope == null || submitted == true || !getCanSign()) {
            return null;
        }
        if (String.isBlank(delegateEmail)) {
            ApexPages.addMessage(new ApexPages.Message(ApexPages.Severity.ERROR, 'Delegate email is required.'));
            return null;
        }
        if (!isValidEmail(delegateEmail)) {
            ApexPages.addMessage(new ApexPages.Message(ApexPages.Severity.ERROR, 'Enter a valid delegate email address.'));
            return null;
        }
        if (String.isBlank(delegateName)) {
            ApexPages.addMessage(new ApexPages.Message(ApexPages.Severity.ERROR, 'Delegate name is required.'));
            return null;
        }
        if (String.isBlank(delegateMessage)) {
            ApexPages.addMessage(new ApexPages.Message(ApexPages.Severity.ERROR, 'A message is required when delegating this agreement.'));
            return null;
        }
        if (delegateTermsAccepted != true) {
            ApexPages.addMessage(new ApexPages.Message(ApexPages.Severity.ERROR, 'You must confirm the disclosure before delegating.'));
            return null;
        }
        try {
            String resolvedEmail = delegateEmail.trim();
            String resolvedName = delegateName.trim();
            String resolvedMessage = delegateMessage.trim();
            Map<String, Object> payload = new Map<String, Object>();
            payload.put('delegateEmail', resolvedEmail);
            payload.put('delegateName', resolvedName);
            payload.put('delegateMessage', resolvedMessage);
            payload.put('previousSignerEmail', envelope.Signer_Email__c);
            payload.put('previousSignerName', envelope.Signer_Name__c);
            payload.put('message', resolvedMessage);
            publishCommand('Delegated', payload, true);
            submitted = true;
            pageMessage = 'This signature request has been delegated to ' + resolvedEmail + '.';
        } catch (Exception e) {
            ApexPages.addMessage(new ApexPages.Message(ApexPages.Severity.ERROR, e.getMessage()));
        }
        return null;
    }

    public PageReference continueAfterDisclosure() {
        loadEnvelope();
        if (!getCanSign()) {
            return null;
        }
        consent = true;
        disclosureAccepted = true;
        publishCommand('Disclosure Accepted', new Map<String, Object>{
            'message' => 'Signer accepted Consumer Disclosure and consented to use electronic signatures.'
        }, false);
        return null;
    }

    public PageReference declineDisclosure() {
        declineReason = 'Signer declined electronic records and signatures consent.';
        declineTermsAccepted = true;
        return decline();
    }

    private static Boolean isValidEmail(String value) {
        if (String.isBlank(value)) {
            return false;
        }
        String normalized = value.trim();
        Integer atIndex = normalized.indexOf('@');
        Integer dotIndex = normalized.lastIndexOf('.');
        return normalized.indexOf(' ') < 0 &&
            atIndex > 0 &&
            dotIndex > atIndex + 1 &&
            dotIndex < normalized.length() - 1;
    }

    private void validateSubmittedFieldsOnly() {
        Map<Id, String> submittedValues = submittedFieldValueMap(signerFieldsJson);
        List<ESignature_Field__c> fields = [
            SELECT Id, Field_Type__c, Label__c, Required__c
            FROM ESignature_Field__c
            WHERE Envelope__c = :envelope.Id
        ];
        List<String> missing = new List<String>();
        for (ESignature_Field__c field : fields) {
            String value = submittedValues.get(field.Id);
            if (field.Required__c && String.isBlank(value)) {
                missing.add(String.isBlank(field.Label__c) ? field.Field_Type__c : field.Label__c);
            }
        }
        if (!missing.isEmpty()) {
            throw new ESignatureUtil.AppException('Complete required fields before signing: ' + String.join(missing, ', '));
        }
    }

    private Map<Id, String> submittedFieldValueMap(String rawJson) {
        Map<Id, String> submittedValues = new Map<Id, String>();
        if (!String.isBlank(rawJson)) {
            List<Object> rows = (List<Object>) JSON.deserializeUntyped(rawJson);
            for (Object item : rows) {
                Map<String, Object> row = (Map<String, Object>) item;
                Id fieldId = ESignatureUtil.safeId(ESignatureUtil.stringValue(row.get('id')));
                if (fieldId != null) {
                    submittedValues.put(fieldId, ESignatureUtil.stringValue(row.get('value')));
                }
            }
        }
        return submittedValues;
    }

    private String titleFromSubmittedFields(String rawJson) {
        Map<Id, String> submittedValues = submittedFieldValueMap(rawJson);
        if (submittedValues.isEmpty()) {
            return null;
        }
        for (ESignature_Field__c field : [
            SELECT Id, Field_Type__c
            FROM ESignature_Field__c
            WHERE Envelope__c = :envelope.Id
            AND Field_Type__c = 'Title'
        ]) {
            String value = submittedValues.get(field.Id);
            if (!String.isBlank(value)) {
                return value.trim();
            }
        }
        return null;
    }

    private Boolean isCompletedEnvelope() {
        if (envelope == null) {
            return false;
        }
        return new Set<String>{ 'signed', 'completed', 'complete' }.contains(normalizedEnvelopeStatus()) &&
            !String.isBlank(envelope.Final_ContentVersion_Id__c);
    }

    private Boolean isCancelledEnvelope() {
        String status = normalizedEnvelopeStatus();
        return new Set<String>{ 'cancelled', 'canceled', 'voided', 'cancelled by sender', 'canceled by sender' }.contains(status) ||
            status.contains('cancel') ||
            status.contains('void');
    }

    private Boolean isDeclinedEnvelope() {
        if (envelope == null) {
            return false;
        }
        if (!String.isBlank(ESignatureUtil.stringValue(envelope.Decline_Reason__c))) {
            return true;
        }
        String status = normalizedEnvelopeStatus();
        return status == 'declined' ||
            status.contains('declin') ||
            status.contains('reject');
    }

    private String normalizedEnvelopeStatus() {
        if (envelope == null) {
            return '';
        }
        String status = ESignatureUtil.stringValue(envelope.Status__c);
        return String.isBlank(status) ? '' : status.trim().toLowerCase();
    }

    private void publishCommand(String action, Map<String, Object> payload, Boolean required) {
        try {
            if (payload == null) {
                payload = new Map<String, Object>();
            }
            ESignatureUtil.addCurrentRequestContext(payload);
            ESignatureUtil.publishSignerCommand(action, envelope, token, payload, required);
        } catch (Exception e) {
            if (required) {
                throw e;
            }
        }
    }

    private static String pdfFileName(String title) {
        String fileName = sanitizeFileName(title);
        if (!fileName.toLowerCase().endsWith('.pdf')) {
            fileName += '.pdf';
        }
        return fileName;
    }

    private static String sanitizeFileName(String value) {
        String cleaned = String.isBlank(value) ? 'Document' : value.trim();
        cleaned = cleaned.replaceAll('[\\\\/:*?"<>|\\r\\n\\t]', ' ');
        cleaned = cleaned.replaceAll('\\s+', ' ').trim();
        while (cleaned.endsWith('.')) {
            cleaned = cleaned.substring(0, cleaned.length() - 1).trim();
        }
        if (String.isBlank(cleaned)) {
            cleaned = 'Document';
        }
        if (cleaned.length() > 180) {
            cleaned = cleaned.substring(0, 180).trim();
        }
        return cleaned;
    }
}
