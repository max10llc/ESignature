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
    public static List<EnvelopeDTO> getDraftEnvelopes(String parentRecordId, String refreshKey) {
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
                   Expires_At__c, Public_Signing_URL__c, Sender_User__c,
                   Source_File_Title__c, Source_ContentVersion_Id__c, Source_ContentDocument_Id__c
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
        stampSourceFields(env);
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

    private static void stampSourceFields(PDF_ESignature_Envelope__c env) {
        ContentVersion source = PDFESignatureUtil.getLatestSourceVersion(env, false);
        if (source == null) {
            return;
        }
        env.Source_ContentVersion_Id__c = String.valueOf(source.Id);
        env.Source_ContentDocument_Id__c = String.valueOf(source.ContentDocumentId);
        env.Source_File_Title__c = source.Title;
    }

    private static void sendEmail(PDF_ESignature_Envelope__c env, String signingUrl) {
        Messaging.SingleEmailMessage message = new Messaging.SingleEmailMessage();
        message.setToAddresses(new List<String>{ env.Signer_Email__c });
        String documentTitle = PDFESignatureUtil.getEnvelopeTitle(env);
        message.setSubject('Signature requested: ' + documentTitle);
        message.setHtmlBody(buildSignatureRequestEmailHtml(env, signingUrl, documentTitle));
        message.setSaveAsActivity(false);
        Messaging.sendEmail(new List<Messaging.SingleEmailMessage>{ message });
    }

    @TestVisible
    private static String buildSignatureRequestEmailHtml(PDF_ESignature_Envelope__c env, String signingUrl, String documentTitle) {
        String safeSignerName = String.isBlank(env.Signer_Name__c) ? 'there' : PDFESignatureUtil.escapeHtml(env.Signer_Name__c);
        String safeDocumentTitle = String.isBlank(documentTitle) ? 'Document' : PDFESignatureUtil.escapeHtml(documentTitle);
        String safeSigningUrl = PDFESignatureUtil.escapeHtml(signingUrl);
        String senderName = String.isBlank(UserInfo.getName()) ? 'The sender' : PDFESignatureUtil.escapeHtml(UserInfo.getName());
        String safeExpirationDate = formatDateForEmail(env.Expires_At__c == null ? System.now().addDays(365) : env.Expires_At__c);

        return emailShell(
            emailParagraphRow('Hi ' + safeSignerName + ',')
            + emailParagraphRow(senderName + ' has sent you a document that requires your signature:')
            + emailDocumentBlockRow('Document', safeDocumentTitle, '#0176d3')
            + emailParagraphRow('Please review and sign the agreement.')
            + emailButtonRow('Review &amp; Sign Document', safeSigningUrl, '#0176d3')
            + emailSubtleRow('This link is unique to you and will expire on ' + safeExpirationDate + '.')
            + emailSubtleRow('If the button above does not work, copy and paste this URL into your browser:<br/><a href="' + safeSigningUrl + '" style="color:#0176d3;text-decoration:underline;word-break:break-all;">' + safeSigningUrl + '</a>')
        );
    }

    private static String emailLogoUrl() {
        return URL.getOrgDomainUrl().toExternalForm() + '/resource/Kaizon_Solutions_Logo';
    }

    private static String emailShell(String contentHtml) {
        return ''
            + '<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="width:100%;background-color:#ffffff;margin:0;padding:0;border-collapse:collapse;">'
            + '  <tr>'
            + '    <td align="center" style="padding:24px 10px 24px 10px;">'
            + '      <table role="presentation" width="600" cellpadding="0" cellspacing="0" border="0" style="width:600px;background-color:#ffffff;border:1px solid #e5e7eb;border-collapse:collapse;">'
            + '        <tr>'
            + '          <td bgcolor="#0176d3" height="44" style="height:44px;background-color:#0176d3;font-size:0;line-height:44px;mso-line-height-rule:exactly;">&nbsp;</td>'
            + '        </tr>'
            + '        <tr>'
            + '          <td align="left" style="padding:18px 24px 14px 24px;border-bottom:1px solid #e5e7eb;">'
            + '            <img src="' + emailLogoUrl() + '" width="300" alt="Kaizon Solutions" style="display:block;width:300px;max-width:300px;height:auto;border:0;outline:none;text-decoration:none;-ms-interpolation-mode:bicubic;" />'
            + '          </td>'
            + '        </tr>'
            +          nullToBlank(contentHtml)
            + '      </table>'
            + '    </td>'
            + '  </tr>'
            + '</table>';
    }

    private static String emailRow(String innerHtml) {
        return '<tr><td style="padding:0 24px 16px 24px;font-family:Arial,Helvetica,sans-serif;font-size:14px;line-height:20px;color:#374151;">' + nullToBlank(innerHtml) + '</td></tr>';
    }

    private static String emailParagraphRow(String safeHtml) {
        return emailRow('<p style="Margin:0;font-family:Arial,Helvetica,sans-serif;font-size:14px;line-height:20px;color:#374151;">' + nullToBlank(safeHtml) + '</p>');
    }

    private static String emailSubtleRow(String safeHtml) {
        return emailRow('<p style="Margin:0;font-family:Arial,Helvetica,sans-serif;font-size:12px;line-height:18px;color:#64748b;">' + nullToBlank(safeHtml) + '</p>');
    }

    private static String emailDocumentBlockRow(String label, String safeTitle, String accentColor) {
        String color = String.isBlank(accentColor) ? '#0176d3' : accentColor;
        return ''
            + '<tr>'
            + '  <td style="padding:0 24px 18px 24px;">'
            + '    <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="width:100%;border-collapse:collapse;background-color:#f7f8fa;border-left:4px solid ' + color + ';">'
            + '      <tr>'
            + '        <td style="padding:13px 16px;font-family:Arial,Helvetica,sans-serif;">'
            + '          <div style="font-size:12px;line-height:16px;color:#64748b;Margin:0 0 6px 0;">' + PDFESignatureUtil.escapeHtml(label) + '</div>'
            + '          <div style="font-size:15px;line-height:20px;font-weight:bold;color:#111827;Margin:0;">' + nullToBlank(safeTitle) + '</div>'
            + '        </td>'
            + '      </tr>'
            + '    </table>'
            + '  </td>'
            + '</tr>';
    }

    private static String emailButtonRow(String safeLabel, String safeUrl, String backgroundColor) {
        String color = String.isBlank(backgroundColor) ? '#0176d3' : backgroundColor;
        return ''
            + '<tr>'
            + '  <td align="center" style="padding:8px 24px 22px 24px;">'
            + '    <table role="presentation" cellpadding="0" cellspacing="0" border="0" style="border-collapse:collapse;">'
            + '      <tr>'
            + '        <td bgcolor="' + color + '" style="background-color:' + color + ';padding:12px 24px;font-family:Arial,Helvetica,sans-serif;font-size:14px;line-height:18px;font-weight:bold;text-align:center;">'
            + '          <a href="' + nullToBlank(safeUrl) + '" target="_blank" style="color:#ffffff;text-decoration:none;display:block;">' + nullToBlank(safeLabel) + '</a>'
            + '        </td>'
            + '      </tr>'
            + '    </table>'
            + '  </td>'
            + '</tr>';
    }

    private static String formatDateForEmail(Datetime expirationDate) {
        if (expirationDate == null) {
            return '';
        }
        return expirationDate.format('MMMM d, yyyy');
    }

    private static String nullToBlank(String value) {
        return value == null ? '' : value;
    }
}
