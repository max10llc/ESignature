@IsTest
private class PDFESignatureUtilTest {
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

        System.assertEquals('3', PDFESignatureUtil.estimatePageCount(pdfBlob));
    }

    @IsTest
    static void estimatePageCountFallsBackToOneWhenNoPageMarkersExist() {
        Blob pdfBlob = Blob.valueOf('%PDF-1.4\n1 0 obj << /Type/Pages /Count 0 >> endobj\n%%EOF');

        System.assertEquals('1', PDFESignatureUtil.estimatePageCount(pdfBlob));
    }

    @IsTest
    static void getEnvelopeTitlePrefersStoredSourceContentVersionTitle() {
        PDF_ESignature_Envelope__c env = new PDF_ESignature_Envelope__c(
            Source_File_Title__c = 'Content Version Record Title'
        );

        System.assertEquals('Content Version Record Title', PDFESignatureUtil.getEnvelopeTitle(env));
    }
}
