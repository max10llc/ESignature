trigger ESignatureCommandTrigger on ESignature_Command__e (after insert) {
    PDFESignatureCommandProcessor.process(Trigger.new);
}