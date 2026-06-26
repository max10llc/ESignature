trigger PDFESignatureCommandTrigger on PDF_ESignature_Command__e (after insert) {
    PDFESignatureCommandProcessor.process(Trigger.new);
}