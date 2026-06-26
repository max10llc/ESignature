public without sharing class PDFESignaturePageController {
    public String token { get; private set; }
    public PDF_ESignature_Envelope__c envelope { get; private set; }
    public String typedName { get; set; }
    public String signerTitle { get; set; }
    public String signatureImageDataUrl { get; set; }
    public String signerFieldsJson { get; set; }
    public Boolean consent { get; set; }
    public String declineReason { get; set; }
    public String pageMessage { get; private set; }
    public Boolean hasError { get; private set; }
    public Boolean submitted { get; private set; }

    public PDFESignaturePageController() {
        hasError = false;
        submitted = false;
        consent = false;
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
        if (envelope == null) {
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
        if (envelope.Envelope_Status__c == 'Sent') {
            publishCommand('Viewed', new Map<String, Object>{
                'message' => 'Signer opened the envelope.'
            }, false);
        }
        return null;
    }

    private void loadEnvelope() {
        envelope = PDFESignatureUtil.findEnvelopeByToken(token);
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
        if (envelope.Envelope_Status__c == 'Signed') {
            submitted = true;
            pageMessage = 'This document has already been signed.';
            return;
        }
        if (envelope.Envelope_Status__c == 'Finalizing') {
            submitted = true;
            pageMessage = 'This document has already been submitted and is being finalized.';
            return;
        }
        if (envelope.Envelope_Status__c == 'Declined') {
            submitted = true;
            pageMessage = 'This signature request was declined.';
            return;
        }
    }

    public Boolean getCanSign() {
        return envelope != null && hasError != true && submitted != true &&
            (envelope.Envelope_Status__c == 'Sent' || envelope.Envelope_Status__c == 'Viewed' || envelope.Envelope_Status__c == 'Error');
    }

    public String getDocumentTitle() {
        return PDFESignatureUtil.getEnvelopeTitle(envelope);
    }

    public String getSignerLabel() {
        if (envelope == null) {
            return '';
        }
        return envelope.Signer_Name__c + ' (' + envelope.Signer_Email__c + ')';
    }

    public String getPdfUrl() {
        return PDFESignatureUtil.buildPdfResourceUrl(token);
    }

    public String getFieldsJson() {
        if (envelope == null) {
            return '[]';
        }
        List<Object> output = new List<Object>();
        for (PDF_ESignature_Field__c field : [
            SELECT Id, Field_Type__c, Label__c, Page_Number__c, X_Percent__c, Y_Percent__c,
                   Width_Percent__c, Height_Percent__c, Required__c, Value__c, Completed__c
            FROM PDF_ESignature_Field__c
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
        if (!getCanSign()) {
            return null;
        }
        if (consent != true) {
            ApexPages.addMessage(new ApexPages.Message(ApexPages.Severity.ERROR, 'You must agree to sign electronically.'));
            return null;
        }
        if (String.isBlank(typedName)) {
            ApexPages.addMessage(new ApexPages.Message(ApexPages.Severity.ERROR, 'Type your full legal name.'));
            return null;
        }
        if (String.isBlank(signerTitle)) {
            ApexPages.addMessage(new ApexPages.Message(ApexPages.Severity.ERROR, 'Enter your title.'));
            return null;
        }
        try {
            validateSubmittedFieldsOnly();
            Map<String, Object> payload = new Map<String, Object>();
            payload.put('typedName', typedName.trim());
            payload.put('signerTitle', signerTitle.trim());
            payload.put('signatureImageDataUrl', signatureImageDataUrl);
            payload.put('signatureMethod', String.isBlank(signatureImageDataUrl) ? 'Typed' : 'Drawn');
            payload.put('signerFieldsJson', signerFieldsJson);
            payload.put('message', 'Signer completed required fields and submitted signature.');
            publishCommand('Signed', payload, true);
            submitted = true;
            pageMessage = 'Thank you. Your signature was submitted and the signed PDF is being finalized.';
        } catch (Exception e) {
            ApexPages.addMessage(new ApexPages.Message(ApexPages.Severity.ERROR, e.getMessage()));
        }
        return null;
    }

    public PageReference decline() {
        if (envelope == null || submitted == true) {
            return null;
        }
        try {
            Map<String, Object> payload = new Map<String, Object>();
            payload.put('declineReason', declineReason);
            payload.put('message', declineReason);
            publishCommand('Declined', payload, true);
            submitted = true;
            pageMessage = 'This signature request has been declined.';
        } catch (Exception e) {
            ApexPages.addMessage(new ApexPages.Message(ApexPages.Severity.ERROR, e.getMessage()));
        }
        return null;
    }

    private void validateSubmittedFieldsOnly() {
        Map<Id, String> submittedValues = submittedFieldValueMap(signerFieldsJson);
        List<PDF_ESignature_Field__c> fields = [
            SELECT Id, Field_Type__c, Label__c, Required__c
            FROM PDF_ESignature_Field__c
            WHERE Envelope__c = :envelope.Id
        ];
        List<String> missing = new List<String>();
        for (PDF_ESignature_Field__c field : fields) {
            String value = submittedValues.get(field.Id);
            if (field.Field_Type__c == 'Signature' && String.isBlank(value)) {
                value = typedName;
            } else if (field.Field_Type__c == 'Name' && String.isBlank(value)) {
                value = typedName;
            } else if (field.Field_Type__c == 'Title' && String.isBlank(value)) {
                value = signerTitle;
            } else if (field.Field_Type__c == 'Date' && String.isBlank(value)) {
                value = Date.today().format();
            } else if (field.Field_Type__c == 'Initials' && String.isBlank(value)) {
                value = initialsForName(typedName);
            }
            if (field.Required__c && String.isBlank(value)) {
                missing.add(String.isBlank(field.Label__c) ? field.Field_Type__c : field.Label__c);
            }
        }
        if (!missing.isEmpty()) {
            throw new PDFESignatureUtil.AppException('Complete required fields before signing: ' + String.join(missing, ', '));
        }
    }

    private Map<Id, String> submittedFieldValueMap(String rawJson) {
        Map<Id, String> submittedValues = new Map<Id, String>();
        if (!String.isBlank(rawJson)) {
            List<Object> rows = (List<Object>) JSON.deserializeUntyped(rawJson);
            for (Object item : rows) {
                Map<String, Object> row = (Map<String, Object>) item;
                Id fieldId = PDFESignatureUtil.safeId(PDFESignatureUtil.stringValue(row.get('id')));
                if (fieldId != null) {
                    submittedValues.put(fieldId, PDFESignatureUtil.stringValue(row.get('value')));
                }
            }
        }
        return submittedValues;
    }

    private void publishCommand(String action, Map<String, Object> payload, Boolean required) {
        try {
            if (payload == null) {
                payload = new Map<String, Object>();
            }
            PDFESignatureUtil.addCurrentRequestContext(payload);
            PDFESignatureUtil.publishSignerCommand(action, envelope, token, payload, required);
        } catch (Exception e) {
            if (required) {
                throw e;
            }
        }
    }

    private String initialsForName(String value) {
        if (String.isBlank(value)) {
            return '';
        }
        List<String> parts = value.trim().split('\\s+');
        String output = '';
        for (String part : parts) {
            if (!String.isBlank(part)) {
                output += part.left(1).toUpperCase();
            }
        }
        return output;
    }
}