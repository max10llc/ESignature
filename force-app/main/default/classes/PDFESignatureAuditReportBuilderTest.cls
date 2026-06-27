@IsTest
private class PDFESignatureAuditReportBuilderTest {
    @IsTest
    static void buildsReportPdfFromEnvelopeAuditEvents() {
        PDF_ESignature_Envelope__c env = new PDF_ESignature_Envelope__c(
            Envelope_Status__c = 'Signed',
            Source_File_Title__c = 'Audit Report Contract',
            Parent_Object_Api_Name__c = 'Opportunity',
            Signer_Name__c = 'Derek Hawley',
            Signer_Email__c = 'derek.hawley@example.com',
            Signer_Title__c = 'President',
            Sender_User__c = UserInfo.getUserId(),
            Sent_At__c = DateTime.newInstanceGmt(2026, 6, 23, 14, 0, 0),
            Viewed_At__c = DateTime.newInstanceGmt(2026, 6, 23, 14, 5, 0),
            Signed_At__c = DateTime.newInstanceGmt(2026, 6, 23, 14, 10, 0),
            Signature_Method__c = 'Typed'
        );
        insert env;

        insert new List<PDF_ESignature_Audit_Event__c>{
            audit(env.Id, 'Sent', 'Envelope sent to derek.hawley@example.com.', DateTime.newInstanceGmt(2026, 6, 23, 14, 0, 0)),
            audit(env.Id, 'Viewed', 'Signer opened the envelope.', DateTime.newInstanceGmt(2026, 6, 23, 14, 5, 0)),
            audit(env.Id, 'Signed', 'Signer completed required fields and submitted signature.', DateTime.newInstanceGmt(2026, 6, 23, 14, 10, 0))
        };

        String reportPdfBase64 = PDFESignatureAuditReportBuilder.buildAuditReportBase64(env.Id, null);
        System.assert(String.isNotBlank(reportPdfBase64), 'Report PDF base64 should be returned.');

        String pdfText = EncodingUtil.base64Decode(reportPdfBase64).toString();
        System.assert(pdfText.startsWith('%PDF-1.4'), 'Report output should be a PDF.');
        System.assert(pdfText.contains('Final Audit Report'), 'Report should include the audit heading.');
        System.assert(pdfText.contains('Audit Report Contract'), 'Report should include the document title.');
        System.assert(pdfText.contains('Derek Hawley'), 'Report should include the signer name.');
        System.assert(pdfText.contains('Document emailed'), 'Report should include the sent event row.');
        System.assert(pdfText.contains('Signer accessed secure link'), 'Report should include the viewed event row.');
        System.assert(pdfText.contains('Document e-signed'), 'Report should include the signed event row.');
        System.assert(pdfText.contains('Agreement completed'), 'Report should include the completion row.');
    }

    @IsTest
    static void suppliedSourceTitleOverridesEnvelopeTitle() {
        PDF_ESignature_Envelope__c env = new PDF_ESignature_Envelope__c(
            Envelope_Status__c = 'Signed',
            Source_File_Title__c = 'Envelope Stored Title',
            Signer_Name__c = 'Derek Hawley',
            Signer_Email__c = 'derek.hawley@example.com',
            Signed_At__c = DateTime.newInstanceGmt(2026, 6, 23, 14, 10, 0),
            Signature_Method__c = 'Typed'
        );
        insert env;

        String pdfText = EncodingUtil.base64Decode(
            PDFESignatureAuditReportBuilder.buildAuditReportBase64(env.Id, 'Source Version Title')
        ).toString();

        System.assert(pdfText.contains('Source Version Title'), 'The finalizer source title should be used when provided.');
    }

    private static PDF_ESignature_Audit_Event__c audit(Id envelopeId, String typeValue, String details, Datetime occurredAt) {
        return new PDF_ESignature_Audit_Event__c(
            Envelope__c = envelopeId,
            Event_Type__c = typeValue,
            Occurred_At__c = occurredAt,
            Actor_Email__c = 'derek.hawley@example.com',
            Details__c = details,
            IP_Address__c = '203.0.113.10',
            User_Agent__c = 'Unit Test'
        );
    }
}
