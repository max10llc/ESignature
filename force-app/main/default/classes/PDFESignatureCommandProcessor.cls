public without sharing class PDFESignatureCommandProcessor {
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
                   Completed_Fields_JSON__c, Completion_Message__c, Decline_Reason__c, Error_Message__c
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
        audit(env, 'Declined', payload, env.Decline_Reason__c);
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
        if (String.isBlank(signerTitle)) {
            throw new PDFESignatureUtil.AppException('Enter your title.');
        }

        String signerFieldsJson = PDFESignatureUtil.stringValue(payload.get('signerFieldsJson'));
        applySubmittedFields(env, signerFieldsJson, typedName, signerTitle);

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

    private static void applySubmittedFields(PDF_ESignature_Envelope__c env, String signerFieldsJson, String typedName, String signerTitle) {
        Map<Id, String> submittedValues = submittedFieldValueMap(signerFieldsJson);
        List<PDF_ESignature_Field__c> fields = [
            SELECT Id, Field_Type__c, Label__c, Required__c, Value__c, Completed__c, Completed_At__c
            FROM PDF_ESignature_Field__c
            WHERE Envelope__c = :env.Id
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
            Boolean complete = !String.isBlank(value);
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

    private static void markError(PDF_ESignature_Envelope__c env, Map<String, Object> payload, String message) {
        try {
            env.Envelope_Status__c = 'Error';
            env.Error_Message__c = truncate(message, 32768);
            update env;
            audit(env, 'Error', payload, truncate(message, 32768));
        } catch (Exception ignore) {}
    }

    private static String initialsForName(String value) {
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

    private static String trimToNull(String value) {
        if (String.isBlank(value)) {
            return null;
        }
        return value.trim();
    }

    private static String truncate(String value, Integer maxLength) {
        if (value == null || maxLength == null || value.length() <= maxLength) {
            return value;
        }
        return value.left(maxLength);
    }
}