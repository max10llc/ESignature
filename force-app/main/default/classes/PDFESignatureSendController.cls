public with sharing class PDFESignatureSendController {
    public class EnvelopeDTO {
        @AuraEnabled public String id;
        @AuraEnabled public String name;
        @AuraEnabled public String title;
        @AuraEnabled public String status;
        @AuraEnabled public Integer fieldCount;
        @AuraEnabled public Datetime lastModifiedDate;
    }

    public class SendResultDTO {
        @AuraEnabled public String envelopeId;
        @AuraEnabled public String signingUrl;
        @AuraEnabled public String status;
        @AuraEnabled public String message;
    }

    @AuraEnabled(cacheable=true)
    public static List<EnvelopeDTO> getDraftEnvelopes(String parentRecordId) {
        List<EnvelopeDTO> output = new List<EnvelopeDTO>();
        List<PDF_ESignature_Envelope__c> envelopes = [
            SELECT Id, Name, Envelope_Status__c, LastModifiedDate,
                   (SELECT Id FROM PDF_ESignature_Fields__r)
            FROM PDF_ESignature_Envelope__c
            WHERE Parent_Record_Id__c = :parentRecordId
            AND (Envelope_Status__c = 'Draft' OR Envelope_Status__c = null)
            ORDER BY LastModifiedDate DESC
            LIMIT 50
        ];
        Set<Id> envelopeIds = new Set<Id>();
        for (PDF_ESignature_Envelope__c env : envelopes) {
            envelopeIds.add(env.Id);
        }
        Map<Id, Id> documentIdByEnvelopeId = PDFESignatureUtil.getSourceDocumentIdsByEnvelopeId(envelopeIds);
        Set<Id> documentIds = new Set<Id>();
        for (Id documentId : documentIdByEnvelopeId.values()) {
            if (documentId != null) {
                documentIds.add(documentId);
            }
        }
        Map<Id, String> titleByDocumentId = PDFESignatureUtil.getContentDocumentTitles(documentIds);
        for (PDF_ESignature_Envelope__c env : envelopes) {
            EnvelopeDTO row = new EnvelopeDTO();
            row.id = env.Id;
            row.name = env.Name;
            row.title = PDFESignatureUtil.titleFromEnvelope(env, titleByDocumentId, documentIdByEnvelopeId);
            row.status = String.isBlank(env.Envelope_Status__c) ? 'Draft' : env.Envelope_Status__c;
            row.lastModifiedDate = env.LastModifiedDate;
            row.fieldCount = env.PDF_ESignature_Fields__r == null ? 0 : env.PDF_ESignature_Fields__r.size();
            output.add(row);
        }
        return output;
    }

    @AuraEnabled
    public static SendResultDTO sendEnvelope(String envelopeId, String signerName, String signerEmail, String signerTitle, Integer expirationDays) {
        if (String.isBlank(envelopeId)) {
            throw new AuraHandledException('Select a draft envelope to send.');
        }
        if (String.isBlank(signerName)) {
            throw new AuraHandledException('Signer name is required.');
        }
        if (String.isBlank(signerEmail)) {
            throw new AuraHandledException('Signer email is required.');
        }
        PDF_ESignature_Envelope__c env = [
            SELECT Id, Name, Envelope_Status__c, Parent_Record_Id__c, Secure_Token_Hash__c,
                   Signer_Name__c, Signer_Email__c, Signer_Title__c, Sent_At__c,
                   Expires_At__c, Public_Signing_URL__c, Sender_User__c
            FROM PDF_ESignature_Envelope__c
            WHERE Id = :envelopeId
            LIMIT 1
        ];
        if (!String.isBlank(env.Envelope_Status__c) && env.Envelope_Status__c != 'Draft') {
            throw new AuraHandledException('Only draft envelopes can be sent. Current status: ' + env.Envelope_Status__c);
        }
        Integer fieldCount = [SELECT COUNT() FROM PDF_ESignature_Field__c WHERE Envelope__c = :env.Id];
        if (fieldCount == 0) {
            throw new AuraHandledException('Add at least one field before sending the envelope.');
        }
        PDF_ESignature_Setting__mdt settings = PDFESignatureUtil.getSettings();
        Integer days = expirationDays == null || expirationDays <= 0
            ? (settings.Default_Expiration_Days__c == null ? 365 : Integer.valueOf(settings.Default_Expiration_Days__c))
            : expirationDays;
        if (days > 365) {
            days = 365;
        }
        String token = PDFESignatureUtil.generateToken();
        String signingUrl = PDFESignatureUtil.buildSigningUrl(token);
        env.Secure_Token_Hash__c = PDFESignatureUtil.hashToken(token);
        env.Signer_Name__c = signerName.trim();
        env.Signer_Email__c = signerEmail.trim();
        env.Signer_Title__c = String.isBlank(signerTitle) ? null : signerTitle.trim();
        env.Envelope_Status__c = 'Sent';
        env.Sent_At__c = System.now();
        env.Expires_At__c = System.now().addDays(days);
        env.Public_Signing_URL__c = signingUrl;
        env.Sender_User__c = UserInfo.getUserId();
        update env;

        try {
            PDFESignatureUtil.cacheSourcePdfForEnvelope(env.Id);
        } catch (Exception ex) {
            env.Envelope_Status__c = 'Error';
            env.Error_Message__c = 'Unable to cache source PDF for public signing: ' + ex.getMessage();
            update env;
            throw new AuraHandledException('Unable to cache source PDF for public signing: ' + ex.getMessage());
        }

        sendEmail(env, signingUrl);
        PDFESignatureUtil.audit(env.Id, 'Sent', UserInfo.getUserEmail(), 'Envelope sent to ' + env.Signer_Email__c + '.');

        SendResultDTO result = new SendResultDTO();
        result.envelopeId = env.Id;
        result.signingUrl = signingUrl;
        result.status = env.Envelope_Status__c;
        result.message = 'Envelope sent to ' + env.Signer_Email__c + '.';
        return result;
    }

    private static void sendEmail(PDF_ESignature_Envelope__c env, String signingUrl) {
        Messaging.SingleEmailMessage message = new Messaging.SingleEmailMessage();
        message.setToAddresses(new List<String>{ env.Signer_Email__c });
        String documentTitle = PDFESignatureUtil.getEnvelopeTitle(env);
        message.setSubject('Signature requested: ' + documentTitle);
        String body = ''
            + '<div style="font-family:Arial,sans-serif;font-size:15px;color:#111827;line-height:1.45">'
            + '<p>Hello ' + PDFESignatureUtil.escapeHtml(env.Signer_Name__c) + ',</p>'
            + '<p>Please review and sign <strong>' + PDFESignatureUtil.escapeHtml(documentTitle) + '</strong>.</p>'
            + '<p><a href="' + PDFESignatureUtil.escapeHtml(signingUrl) + '" style="display:inline-block;background:#1e51a4;color:#ffffff;padding:12px 18px;text-decoration:none;border-radius:6px;font-weight:bold">Review and Sign</a></p>'
            + '<p>If the button does not work, copy and paste this link into your browser:<br/>'
            + PDFESignatureUtil.escapeHtml(signingUrl) + '</p>'
            + '</div>';
        message.setHtmlBody(body);
        message.setSaveAsActivity(false);
        Messaging.sendEmail(new List<Messaging.SingleEmailMessage>{ message });
    }
}