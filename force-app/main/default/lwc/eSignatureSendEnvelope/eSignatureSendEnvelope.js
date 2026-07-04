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

    get envelopeOptions() {
        return this.envelopes.map((env) => ({
            label: `${env.title || env.name} (${env.fieldCount} fields)`,
            value: env.id
        }));
    }

    get hasDrafts() {
        return this.envelopes.length > 0;
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
            if (this.envelopes.length === 1) {
                this.selectedEnvelopeId = this.envelopes[0].id;
            } else if (!this.envelopes.some((env) => env.id === this.selectedEnvelopeId)) {
                this.selectedEnvelopeId = null;
            }
        } catch (error) {
            this.errorMessage = this.normalizeError(error);
        } finally {
            this.isLoading = false;
        }
    }

    handleRefresh() {
        this.loadDrafts(true);
    }

    handleEnvelopeChange(event) {
        this.selectedEnvelopeId = event.detail.value;
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
