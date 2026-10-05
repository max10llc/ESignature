trigger ESignatureCommandTrigger on ESignature_Command__e (after insert) {
    ESignatureCommandProcessor.process(Trigger.new);
}
