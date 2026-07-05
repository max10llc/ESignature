import { LightningElement, api, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';

import getDraftEnvelopes from '@salesforce/apex/ESignatureSendController.getDraftEnvelopes';
import sendEnvelope from '@salesforce/apex/ESignatureSendController.sendEnvelope';

export default class PdfESignSendEnvelope extends LightningElement {
    @api recordId;
    @api parentRecordId;

    @track envelopes = [];
    selectedEnvelopeId;
    signerName = '';
    signerEmail = '';
    signerTitle = '';
    requestMessage = 'Please review and sign the agreement.';
    expirationDays = 365;
    isLoading = true;
    isSending = false;
    lastSigningUrl;
    errorMessage;
    draftRefreshKey = 'initial';

    connectedCallback() {
        this.loadDrafts();
    }

    get effectiveParentRecordId() {
        return this.parentRecordId || this.recordId;
    }

    get hasDrafts() {
        return this.envelopes.length > 0;
    }

    get currentDraft() {
        return this.envelopes.length ? this.envelopes[0] : null;
    }

    get currentDraftTitle() {
        const draft = this.currentDraft;
        return draft ? draft.title || draft.name : '';
    }

    get currentDraftFieldSummary() {
        const draft = this.currentDraft;
        if (!draft) {
            return '';
        }
        const count = draft.fieldCount || 0;
        return `${count} field${count === 1 ? '' : 's'}`;
    }

    get disableSend() {
        return this.isSending || !this.selectedEnvelopeId || !this.signerName || !this.signerEmail;
    }

    async loadDrafts(forceRefresh = false) {
        this.isLoading = true;
        this.errorMessage = null;
        try {
            if (forceRefresh) {
                this.draftRefreshKey = String(Date.now());
            }
            this.envelopes = await getDraftEnvelopes({
                parentRecordId: this.effectiveParentRecordId,
                refreshKey: this.draftRefreshKey
            });
            this.selectedEnvelopeId = this.currentDraft ? this.currentDraft.id : null;
        } catch (error) {
            this.errorMessage = this.normalizeError(error);
        } finally {
            this.isLoading = false;
        }
    }

    handleRefresh() {
        this.loadDrafts(true);
    }

    handleSignerNameChange(event) {
        this.signerName = event.detail.value;
    }

    handleSignerEmailChange(event) {
        this.signerEmail = event.detail.value;
    }

    handleSignerTitleChange(event) {
        this.signerTitle = event.detail.value;
    }

    handleRequestMessageChange(event) {
        this.requestMessage = event.detail.value;
    }

    handleExpirationChange(event) {
        this.expirationDays = Number(event.detail.value) || 365;
    }

    async handleSend() {
        this.isSending = true;
        this.errorMessage = null;
        this.lastSigningUrl = null;
        try {
            const result = await sendEnvelope({
                envelopeId: this.selectedEnvelopeId,
                signerName: this.signerName,
                signerEmail: this.signerEmail,
                signerTitle: this.signerTitle,
                requestMessage: this.requestMessage,
                expirationDays: this.expirationDays
            });
            this.lastSigningUrl = result.signingUrl;
            this.dispatchEvent(new ShowToastEvent({ title: 'Envelope sent', message: result.message, variant: 'success' }));
            await this.loadDrafts(true);
        } catch (error) {
            this.errorMessage = this.normalizeError(error);
            this.dispatchEvent(new ShowToastEvent({ title: 'Unable to send envelope', message: this.errorMessage, variant: 'error', mode: 'sticky' }));
        } finally {
            this.isSending = false;
        }
    }

    normalizeError(error) {
        if (!error) {
            return 'Unknown error';
        }
        if (Array.isArray(error.body)) {
            return error.body.map((item) => item.message).join(', ');
        }
        if (error.body && error.body.message) {
            return error.body.message;
        }
        return error.message || String(error);
    }
}
