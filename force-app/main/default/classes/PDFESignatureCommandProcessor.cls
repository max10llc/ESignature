public without sharing class PDFESignatureCommandProcessor {
    private class SubmittedFieldResult {
        String titleValue;
    }

    public static void process(List<PDF_ESignature_Command__e> commands) {
        if (commands == null || commands.isEmpty()) {
            return;
        }
        Set<String> tokenHashes = new Set<String>();
        for (PDF_ESignature_Command__e command : commands) {
            if (!String.isBlank(command.Token_Hash__c)) {
                tokenHashes.add(command.Token_Hash__c);
            }
        }
        if (tokenHashes.isEmpty()) {
            return;
        }

        Map<String, PDF_ESignature_Envelope__c> envelopeByHash = new Map<String, PDF_ESignature_Envelope__c>();
        for (PDF_ESignature_Envelope__c env : [
            SELECT Id, Name, Envelope_Status__c, Parent_Record_Id__c, Parent_Object_Api_Name__c,
                   Final_ContentDocument_Id__c, Final_ContentVersion_Id__c, Secure_Token_Hash__c,
                   Signer_Name__c, Signer_Email__c, Signer_Title__c, Sender_User__c,
                   Sent_At__c, Viewed_At__c, Signed_At__c, Expires_At__c, Page_Count__c,
                   Public_Signing_URL__c, Signature_Method__c, Signature_Image_Data_Url__c,
                   Completed_Fields_JSON__c, Completion_Message__c, Decline_Reason__c, Error_Message__c,
                   Source_File_Title__c, Source_ContentVersion_Id__c, Source_ContentDocument_Id__c
            FROM PDF_ESignature_Envelope__c
            WHERE Secure_Token_Hash__c IN :tokenHashes
            FOR UPDATE
        ]) {
            envelopeByHash.put(env.Secure_Token_Hash__c, env);
        }

        for (PDF_ESignature_Command__e command : commands) {
            PDF_ESignature_Envelope__c env = envelopeByHash.get(command.Token_Hash__c);
            if (env == null) {
                continue;
            }
            Map<String, Object> payload = parsePayload(command.Payload_JSON__c);
            try {
                String action = String.isBlank(command.Action__c) ? '' : command.Action__c.trim().toLowerCase();
                if (action == 'viewed') {
                    handleViewed(env, payload);
                } else if (action == 'expired') {
                    handleExpired(env, payload);
                } else if (action == 'signed') {
                    handleSigned(env, payload);
                } else if (action == 'declined') {
                    handleDeclined(env, payload);
                } else if (action == 'delegated') {
                    handleDelegated(env, payload);
                }
            } catch (Exception e) {
                markError(env, payload, e.getMessage() + '\n' + e.getStackTraceString());
            }
        }
    }

    private static void handleViewed(PDF_ESignature_Envelope__c env, Map<String, Object> payload) {
        if (env.Expires_At__c != null && env.Expires_At__c < System.now()) {
            handleExpired(env, payload);
            return;
        }
        if (env.Envelope_Status__c == 'Sent') {
            env.Envelope_Status__c = 'Viewed';
            env.Viewed_At__c = System.now();
            update env;
            audit(env, 'Viewed', payload, 'Signer opened the envelope.');
        }
    }

    private static void handleExpired(PDF_ESignature_Envelope__c env, Map<String, Object> payload) {
        if (env.Envelope_Status__c != 'Expired' && env.Envelope_Status__c != 'Signed' && env.Envelope_Status__c != 'Finalizing') {
            env.Envelope_Status__c = 'Expired';
            update env;
            PDFESignatureUtil.updateSourceFileESignatureStatus(env, 'Canceled');
            audit(env, 'Expired', payload, 'Signing link expired when opened.');
        }
    }

    private static void handleDeclined(PDF_ESignature_Envelope__c env, Map<String, Object> payload) {
        if (env.Envelope_Status__c == 'Signed' || env.Envelope_Status__c == 'Finalizing') {
            return;
        }
        env.Envelope_Status__c = 'Declined';
        env.Decline_Reason__c = PDFESignatureUtil.stringValue(payload.get('declineReason'));
        update env;
        PDFESignatureUtil.updateSourceFileESignatureStatus(env, 'Canceled');
        audit(env, 'Declined', payload, env.Decline_Reason__c);
    }

    private static void handleDelegated(PDF_ESignature_Envelope__c env, Map<String, Object> payload) {
        String status = String.isBlank(env.Envelope_Status__c) ? '' : env.Envelope_Status__c.trim().toLowerCase();
        if (new Set<String>{ 'signed', 'finalizing', 'completed', 'declined', 'expired', 'canceled', 'cancelled' }.contains(status)) {
            return;
        }
        if (env.Expires_At__c != null && env.Expires_At__c < System.now()) {
            handleExpired(env, payload);
            return;
        }

        String delegateEmail = trimToNull(PDFESignatureUtil.stringValue(payload.get('delegateEmail')));
        String delegateName = trimToNull(PDFESignatureUtil.stringValue(payload.get('delegateName')));
        String delegateMessage = trimToNull(PDFESignatureUtil.stringValue(payload.get('delegateMessage')));
        if (!isValidEmail(delegateEmail)) {
            throw new PDFESignatureUtil.AppException('Enter a valid delegate email address.');
        }
        if (String.isBlank(delegateName)) {
            throw new PDFESignatureUtil.AppException('Delegate name is required.');
        }
        if (String.isBlank(delegateMessage)) {
            throw new PDFESignatureUtil.AppException('A message is required when delegating this agreement.');
        }

        String previousSignerEmail = env.Signer_Email__c;
        String previousSignerName = env.Signer_Name__c;
        String newToken = PDFESignatureUtil.generateToken();
        String signingUrl = PDFESignatureUtil.buildSigningUrl(newToken);

        env.Secure_Token_Hash__c = PDFESignatureUtil.hashToken(newToken);
        env.Signer_Name__c = delegateName;
        env.Signer_Email__c = delegateEmail;
        env.Signer_Title__c = null;
        env.Envelope_Status__c = 'Sent';
        env.Sent_At__c = System.now();
        env.Viewed_At__c = null;
        env.Public_Signing_URL__c = signingUrl;
        env.Error_Message__c = null;
        update env;
        PDFESignatureUtil.updateSourceFileESignatureStatus(env, 'Sent');

        sendDelegateEmail(env, signingUrl, delegateMessage, previousSignerName, previousSignerEmail);
        String previousSigner = String.isBlank(previousSignerName) ? previousSignerEmail : previousSignerName + ' (' + previousSignerEmail + ')';
        String details = 'Delegated from ' + previousSigner + ' to ' + delegateName + ' (' + delegateEmail + '). Message: ' + delegateMessage;
        audit(env, 'Delegated', payload, details, previousSignerEmail);
    }

    private static void handleSigned(PDF_ESignature_Envelope__c env, Map<String, Object> payload) {
        if (env.Envelope_Status__c == 'Signed' || env.Envelope_Status__c == 'Finalizing') {
            return;
        }
        if (env.Expires_At__c != null && env.Expires_At__c < System.now()) {
            handleExpired(env, payload);
            return;
        }
        String typedName = trimToNull(PDFESignatureUtil.stringValue(payload.get('typedName')));
        String signerTitle = trimToNull(PDFESignatureUtil.stringValue(payload.get('signerTitle')));
        if (String.isBlank(typedName)) {
            throw new PDFESignatureUtil.AppException('Type your full legal name.');
        }

        String signerFieldsJson = PDFESignatureUtil.stringValue(payload.get('signerFieldsJson'));
        SubmittedFieldResult fieldResult = applySubmittedFields(env, signerFieldsJson);
        if (String.isBlank(signerTitle)) {
            signerTitle = fieldResult.titleValue;
        }

        env.Signer_Name__c = typedName;
        env.Signer_Title__c = signerTitle;
        env.Signed_At__c = System.now();
        env.Envelope_Status__c = 'Finalizing';
        env.Signature_Image_Data_Url__c = PDFESignatureUtil.stringValue(payload.get('signatureImageDataUrl'));
        env.Signature_Method__c = String.isBlank(env.Signature_Image_Data_Url__c) ? 'Typed' : 'Drawn';
        env.Completed_Fields_JSON__c = signerFieldsJson;
        update env;

        audit(env, 'Signed', payload, 'Signer completed required fields and submitted signature.');
        System.enqueueJob(new PDFESignatureFinalizeQueueable(env.Id));
    }

    private static SubmittedFieldResult applySubmittedFields(PDF_ESignature_Envelope__c env, String signerFieldsJson) {
        SubmittedFieldResult result = new SubmittedFieldResult();
        Map<Id, String> submittedValues = submittedFieldValueMap(signerFieldsJson);
        List<PDF_ESignature_Field__c> fields = [
            SELECT Id, Field_Type__c, Label__c, Required__c, Value__c, Completed__c, Completed_At__c
            FROM PDF_ESignature_Field__c
            WHERE Envelope__c = :env.Id
        ];
        List<String> missing = new List<String>();
        for (PDF_ESignature_Field__c field : fields) {
            String value = submittedValues.get(field.Id);
            Boolean complete = !String.isBlank(value);
            if (field.Field_Type__c == 'Title' && String.isBlank(result.titleValue) && complete) {
                result.titleValue = value.trim();
            }
            if (field.Required__c && !complete) {
                missing.add(String.isBlank(field.Label__c) ? field.Field_Type__c : field.Label__c);
            }
            field.Value__c = value;
            field.Completed__c = complete;
            if (complete) {
                field.Completed_At__c = System.now();
            }
        }
        if (!missing.isEmpty()) {
            throw new PDFESignatureUtil.AppException('Complete required fields before signing: ' + String.join(missing, ', '));
        }
        if (!fields.isEmpty()) {
            update fields;
        }
        return result;
    }

    private static Map<Id, String> submittedFieldValueMap(String rawJson) {
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

    private static Map<String, Object> parsePayload(String rawJson) {
        if (String.isBlank(rawJson)) {
            return new Map<String, Object>();
        }
        try {
            return (Map<String, Object>) JSON.deserializeUntyped(rawJson);
        } catch (Exception e) {
            return new Map<String, Object>();
        }
    }

    private static void audit(PDF_ESignature_Envelope__c env, String eventType, Map<String, Object> payload, String details) {
        if (env == null || env.Id == null) {
            return;
        }
        PDF_ESignature_Audit_Event__c evt = new PDF_ESignature_Audit_Event__c();
        evt.Envelope__c = env.Id;
        evt.Event_Type__c = eventType;
        evt.Occurred_At__c = System.now();
        evt.Actor_Email__c = env.Signer_Email__c;
        evt.Details__c = details;
        evt.User_Agent__c = truncate(PDFESignatureUtil.stringValue(payload.get('userAgent')), 255);
        evt.IP_Address__c = truncate(PDFESignatureUtil.stringValue(payload.get('ipAddress')), 80);
        insert evt;
    }

    private static void audit(PDF_ESignature_Envelope__c env, String eventType, Map<String, Object> payload, String details, String actorEmail) {
        if (env == null || env.Id == null) {
            return;
        }
        PDF_ESignature_Audit_Event__c evt = new PDF_ESignature_Audit_Event__c();
        evt.Envelope__c = env.Id;
        evt.Event_Type__c = eventType;
        evt.Occurred_At__c = System.now();
        evt.Actor_Email__c = actorEmail;
        evt.Details__c = details;
        evt.User_Agent__c = truncate(PDFESignatureUtil.stringValue(payload.get('userAgent')), 255);
        evt.IP_Address__c = truncate(PDFESignatureUtil.stringValue(payload.get('ipAddress')), 80);
        insert evt;
    }

    private static void markError(PDF_ESignature_Envelope__c env, Map<String, Object> payload, String message) {
        try {
            env.Envelope_Status__c = 'Error';
            env.Error_Message__c = truncate(message, 32768);
            update env;
            audit(env, 'Error', payload, truncate(message, 32768));
        } catch (Exception ignore) {}
    }

    private static String trimToNull(String value) {
        if (String.isBlank(value)) {
            return null;
        }
        return value.trim();
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

    private static void sendDelegateEmail(
        PDF_ESignature_Envelope__c env,
        String signingUrl,
        String delegateMessage,
        String previousSignerName,
        String previousSignerEmail
    ) {
        Messaging.SingleEmailMessage message = new Messaging.SingleEmailMessage();
        message.setToAddresses(new List<String>{ env.Signer_Email__c });
        String documentTitle = PDFESignatureUtil.getEnvelopeTitle(env);
        String delegator = String.isBlank(previousSignerName) ? previousSignerEmail : previousSignerName;
        String escapedMessage = PDFESignatureUtil.escapeHtml(delegateMessage)
            .replace('\r\n', '<br/>')
            .replace('\n', '<br/>')
            .replace('\r', '<br/>');
        message.setSubject('Signature delegated: ' + documentTitle);
        String body = ''
            + '<div style="font-family:Arial,sans-serif;font-size:15px;color:#111827;line-height:1.45">'
            + '<p>Hello ' + PDFESignatureUtil.escapeHtml(env.Signer_Name__c) + ',</p>'
            + '<p>' + PDFESignatureUtil.escapeHtml(delegator) + ' delegated <strong>' + PDFESignatureUtil.escapeHtml(documentTitle) + '</strong> to you for signature.</p>'
            + '<p><strong>Message:</strong><br/>' + escapedMessage + '</p>'
            + '<p><a href="' + PDFESignatureUtil.escapeHtml(signingUrl) + '" style="display:inline-block;background:#1e51a4;color:#ffffff;padding:12px 18px;text-decoration:none;border-radius:6px;font-weight:bold">Review and Sign</a></p>'
            + '<p>If the button does not work, copy and paste this link into your browser:<br/>'
            + PDFESignatureUtil.escapeHtml(signingUrl) + '</p>'
            + '</div>';
        message.setHtmlBody(body);
        message.setSaveAsActivity(false);
        Messaging.sendEmail(new List<Messaging.SingleEmailMessage>{ message });
    }

    private static String truncate(String value, Integer maxLength) {
        if (value == null || maxLength == null || value.length() <= maxLength) {
            return value;
        }
        return value.left(maxLength);
    }
}
