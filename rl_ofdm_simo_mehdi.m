
clc
clear
close all;

[version, executable, isloaded] = pyversion;
if ~isloaded
    pyversion /usr/bin/python
    py.print() %weird bug where py isn't loaded in an external script
end

% Params:
WRITE_PNG_FILES         = 0;           % Enable writing plots to PNG
SIM_MOD                 = 0;
PLOT                        = 0;
% Testing Params:
CFO_ENABLE            = 1;    % Enable inducing CFO in BS antennas
MAX_CFO_PPM         = 5;
SFO_ENABLE            = 0;    % Enable inducing SFO in BS antennas
MAX_SFO_PPM         = 10;
N_max_it = 10;  % Max number of iterations
N_valid_it = 5;     % Number of valid iterations
N_antennas = [8 16 24];   % Number of receiver antennas at BS including 4, 8, 16, 24, and 32

chain2 = ["RF3E000087", "RF3E000084", "RF3E000107", "RF3E000086", "RF3E000110", "RF3E000162", "RF3E000127", "RF3E000597"];
chain3 = ["RF3E000346", "RF3E000543", "RF3E000594", "RF3E000404", "RF3E000616", "RF3E000622", "RF3E000601", "RF3E000602"];
chain4 = ["RF3E000146", "RF3E000122", "RF3E000150", "RF3E000128", "RF3E000168", "RF3E000136", "RF3E000213", "RF3E000142"];
chain5 = ["RF3E000356", "RF3E000546", "RF3E000620", "RF3E000609", "RF3E000604", "RF3E000612", "RF3E000640", "RF3E000551"];
chain6 = ["RF3E000208", "RF3E000636", "RF3E000632", "RF3E000568", "RF3E000558", "RF3E000633", "RF3E000566", "RF3E000635"];

BS_antennas = [chain3 chain4 chain5 chain6 chain2];

if SIM_MOD
    chan_type          = "awgn";
    nt                      = 100;
    sim_SNR_db              = 1:20;
    nsnr                    = length(sim_SNR_db);
    snr_plot                = 20;
    TX_SCALE                = 1;            % Scale for Tx waveform ([0:1])
    N_BS_NODE               = 8;            % x BS NODES (multiple-output)
    N_UE                    = 1;            % 1 UE (single-input)
    bs_ids                  = ones(1, N_BS_NODE);
    ue_ids                  = ones(1, N_UE);

else
    nt                      = 1;
    nsnr                    = 1;
    TX_SCALE                = 1;         % Scale for Tx waveform ([0:1])
    chan_type               = "iris";
    
    %Iris params:
    USE_HUB                 = 1;
    OP_FRQ                  = 3.6e9;
    RX_FRQ                  = OP_FRQ;
    TX_GN                   = 70;
    RX_GN                   = 70;
    OP_SMPL_RT                 = 5e6;  
    N_FRM                   = 10;
    bs_ids = string.empty();
    bs_sched = string.empty();
    ue_ids = string.empty();
    ue_scheds = string.empty();

end
ber_SIM = zeros(nt,nsnr);           % BER
berr_th = zeros(nsnr,1);            % Theoretical BER
fprintf("Channel type: %s \n",chan_type);


% Waveform params
N_OFDM_SYM              = 46;         % Number of OFDM symbols for burst, it needs to be less than 47
MOD_ORDER               = 4;           % Modulation order (2/4/16/64 = BSPK/QPSK/16-QAM/64-QAM)

% OFDM params
SC_IND_PILOTS           = [8 22 44 58];                           % Pilot subcarrier indices
SC_IND_DATA             = [2:7 9:21 23:27 39:43 45:57 59:64];     % Data subcarrier indices
SC_IND_DATA_PILOT       = [2:27 39:64]';
N_SC                    = 64;                                     % Number of subcarriers
CP_LEN                  = 16;                                     % Cyclic prefix length
N_DATA_SYMS             = N_OFDM_SYM * length(SC_IND_DATA);       % Number of data symbols (one per data-bearing subcarrier per OFDM symbol)
N_LTS_SYM               = 2;                                      % Number of 
N_SYM_SAMP              = N_SC + CP_LEN;                          % Number of samples that will go over the air
N_ZPAD_PRE              = 90;                                     % Zero-padding prefix for Iris
N_ZPAD_POST             = N_ZPAD_PRE - 14;                         % Zero-padding postfix for Iris

% Rx processing params
FFT_OFFSET                    = 16;          % Number of CP samples to use in FFT (on average)
DO_APPLY_PHASE_ERR_CORRECTION = 1;           % Enable Residual CFO estimation/correction

%% Define the preamble
% LTS for fine CFO and channel estimation
lts_f = [0 1 -1 -1 1 1 -1 1 -1 1 -1 -1 -1 -1 -1 1 1 -1 -1 1 -1 1 -1 1 1 1 1 0 0 0 0 0 0 0 0 0 0 0 ...
    1 1 -1 -1 1 1 -1 1 -1 1 1 1 1 1 1 -1 -1 1 1 -1 1 -1 1 1 1 1];
lts_t = ifft(lts_f, 64); %time domain
preamble = [lts_t(33:64) lts_t lts_t];

%% Generate a payload of random integers
tx_data = randi(MOD_ORDER, 1, N_DATA_SYMS) - 1;

tx_syms = mod_sym(tx_data, MOD_ORDER);
% Reshape the symbol vector to a matrix with one column per OFDM symbol
tx_syms_mat = reshape(tx_syms, length(SC_IND_DATA), N_OFDM_SYM);

% Define the pilot tone values as BPSK symbols
pilots = [1 1 -1 1].';

% Repeat the pilots across all OFDM symbols
pilots_mat = repmat(pilots, 1, N_OFDM_SYM);

%% IFFT

% Construct the IFFT input matrix
ifft_in_mat = zeros(N_SC, N_OFDM_SYM);

% Insert the data and pilot values; other subcarriers will remain at 0
ifft_in_mat(SC_IND_DATA, :)   = tx_syms_mat;
ifft_in_mat(SC_IND_PILOTS, :) = pilots_mat;

%Perform the IFFT
tx_payload_mat = ifft(ifft_in_mat, N_SC, 1);

% Insert the cyclic prefix
if(CP_LEN > 0)
    tx_cp = tx_payload_mat((end-CP_LEN+1 : end), :);
    tx_payload_mat = [tx_cp; tx_payload_mat];
end

% Reshape to a vector
tx_payload_vec = reshape(tx_payload_mat, 1, numel(tx_payload_mat));


% Construct the full time-domain OFDM waveform
tx_vec = [zeros(1,N_ZPAD_PRE) preamble tx_payload_vec zeros(1,N_ZPAD_POST)];
%tx_vec = [preamble tx_payload_vec];

% Leftover from zero padding:
tx_vec_iris = tx_vec.';
% Scale the Tx vector to +/- 1
tx_vec_iris = TX_SCALE .* tx_vec_iris ./ max(abs(tx_vec_iris));

evm_snr_vec = zeros(2*MAX_CFO_PPM+1,1,length(N_antennas));
pilot_snr_vec = zeros(2*MAX_CFO_PPM+1,1,length(N_antennas));
ber_vec = zeros(2*MAX_CFO_PPM+1,1,length(N_antennas));

for antenna_sw = 1:length(N_antennas)

evm_snr_sw = zeros(2*MAX_CFO_PPM+1,1);
pilot_snr_sw = zeros(2*MAX_CFO_PPM+1,1);
ber_sw = zeros(2*MAX_CFO_PPM+1,1);
% Sweepe CFO
for cfo_sw = 0:0.5:MAX_CFO_PPM
    valid_iteration = 1;
    evm_snr_sw_it = zeros(N_valid_it,1);
    pilot_snr_sw_it = zeros(N_valid_it,1);
    ber_sw_it = zeros(N_valid_it,1);
    for iteration = 1:N_max_it
        valid_it = true;
        if(valid_iteration == N_valid_it + 1)
            break;
        end
for isnr = 1:nsnr
    for it = 1:nt
if (SIM_MOD)

    % Iris nodes' parameters
    n_samp = length(tx_vec_iris);
    bs_sdr_params = struct(...
        'id', bs_ids, ...
        'n_sdrs', N_BS_NODE, ...        % number of nodes chained together
        'txfreq', [], ...
        'rxfreq', [], ...
        'txgain', [], ...
        'rxgain', [], ...
        'sample_rate', [], ...
        'n_samp', n_samp, ...          % number of samples per frame time.
        'n_frame', [], ...
        'tdd_sched', [], ...     % number of zero-paddes samples
        'n_zpad_samp', N_ZPAD_PRE ...
        );

    ue_sdr_params = bs_sdr_params;
    ue_sdr_params.id =  ue_ids;
    ue_sdr_params.n_sdrs = N_UE;
    ue_sdr_params.txgain = [];


    rx_vec_iris = getRxVec(tx_vec_iris, N_BS_NODE, N_UE, chan_type, sim_SNR_db(isnr), bs_sdr_params, ue_sdr_params, []);
    % rx_vec_iris = getRxVec(tx_vec_iris, N_BS_NODE, N_UE, chan_type, sim_SNR_db(isnr));
    rx_vec_iris = rx_vec_iris.'; % just to agree with what the hardware spits out.

else

%% Init Iris nodes
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% Set up the Iris experiment
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

    % Create BS Hub and UE objects. Note: BS object is a collection of Iris
    % nodes.
    
    if USE_HUB
        % Using chains of different size requires some internal
        % calibration on the BS. This functionality will be added later.
        % For now, we use only the 4-node chains:
        
        bs_ids = BS_antennas(1:N_antennas(antenna_sw));
        %bs_ids = ["RF3E000087", "RF3E000084", "RF3E000107", "RF3E000086", "RF3E000110", "RF3E000162", "RF3E000127", "RF3E000597"];
        
        hub_id = "FH4B000019";
        
    else
        bs_ids = BS_antennas(1:N_antennas(antenna_sw));

    end
    
    ue_ids= ["RF3E000164"];

    N_BS_NODE = length(bs_ids);
    N_UE = length(ue_ids);
    
    bs_sched = ["BGGGGGRG"];           % BS schedule
    ue_sched = ["GGGGGGPG"];           % UE schedule

    n_samp = length(tx_vec_iris);
    
    if CFO_ENABLE
        CFO_coef = unifrnd(-cfo_sw, cfo_sw, 1, N_BS_NODE) * 1e-6;
        TX_FRQ = (1 + CFO_coef) * OP_FRQ;
    else
        TX_FRQ = repmat(OP_FRQ, 1, N_BS_NODE);
    end
    
    if SFO_ENABLE
        SFO_coef = unifrnd(-MAX_SFO_PPM, MAX_SFO_PPM, 1, N_BS_NODE) * 1e-6;
        SMPL_RT = (1 + SFO_coef) * OP_SMPL_RT;
    else
        SMPL_RT = repmat(OP_SMPL_RT, 1, N_BS_NODE);
    end
    
    % Iris nodes' parameters
    bs_sdr_params = struct(...
        'id', bs_ids, ...
        'n_sdrs',N_BS_NODE, ...
        'txfreq', TX_FRQ, ...
        'rxfreq', RX_FRQ, ...
        'txgain', TX_GN, ...
        'rxgain', RX_GN, ...
        'sample_rate', SMPL_RT, ...
        'n_samp', n_samp, ...          % number of samples per frame time.
        'n_frame', N_FRM, ...
        'tdd_sched', bs_sched, ...     % number of zero-paddes samples
        'n_zpad_samp', N_ZPAD_PRE ...
        );

    ue_sdr_params = bs_sdr_params;
    ue_sdr_params.id =  ue_ids;
    ue_sdr_params.n_sdrs = 1;
    ue_sdr_params.tdd_sched = ue_sched;
    
    if USE_HUB
        rx_vec_iris = getRxVec(tx_vec_iris, N_BS_NODE, N_UE, chan_type, [], bs_sdr_params, ue_sdr_params, hub_id);
    else
        rx_vec_iris = getRxVec(tx_vec_iris, N_BS_NODE, N_UE, chan_type, [], bs_sdr_params, ue_sdr_params, []);
    end
end
rx_vec_iris = rx_vec_iris.';
l_rx_dec=length(rx_vec_iris);

%% Correlate for LTS

a = 1;
unos = ones(size(preamble.'))';
data_len = (N_OFDM_SYM)*(N_SC +CP_LEN);
rx_lts_mat = double.empty();
payload_ind = int32.empty();
payload_rx = zeros(data_len,N_BS_NODE);
m_filt = zeros(length(rx_vec_iris),N_BS_NODE);
for ibs =1:N_BS_NODE
        v0 = filter(flipud(preamble'),a,rx_vec_iris(:,ibs));
        v1 = filter(unos,a,abs(rx_vec_iris(:,ibs)).^2);
        m_filt(:,ibs) = (abs(v0).^2)./v1; % normalized correlation
        [~, max_idx] = max(m_filt(:,ibs));
        % In case of bad correlatons:
        if (max_idx + data_len) > length(rx_vec_iris) || (max_idx < 0) || (max_idx - length(preamble) < 0)
            fprintf('Bad correlation at antenna %d max_idx = %d \n', ibs, max_idx);
            valid_it = false;
            % Real value doesn't matter since we have corrrupt data:
            max_idx = length(rx_vec_iris)-data_len -1;
        end
        payload_ind(ibs) = max_idx +1;
        lts_ind = payload_ind(ibs) - length(preamble);
        pl_idx = payload_ind(ibs) : payload_ind(ibs) + data_len;
        rx_lts_mat(:,ibs) = rx_vec_iris(lts_ind: lts_ind + length(preamble) -1, ibs );
        payload_rx(1:length(pl_idx) -1,ibs) = rx_vec_iris(payload_ind(ibs) : payload_ind(ibs) + length(pl_idx) -2, ibs);
end
% Just for plotting
lts_corr = sum(m_filt,2);

% Extract LTS for channel estimate
rx_lts_idx1 = -64+-FFT_OFFSET + (97:160);
rx_lts_idx2 = -FFT_OFFSET + (97:160);
% Just for two first brnaches: useful when 1x2 SIMO. Just to illustrate
% improvement of MRC over two branches:

%{
rx_lts_b = zeros(64, 2, N_BS_NODE);
rx_lts_b_f = zeros(64, 2, N_BS_NODE);
for ibs = 1:N_BS_NODE
    rx_lts_b(:,:,ibs) = [rx_lts_mat(rx_lts_idx1,ibs)  rx_lts_mat(rx_lts_idx2,ibs)];
    rx_lts_b_f(:,:,ibs) = fft(rx_lts_b(:,:,ibs));
    H0_b(:,:,ibs) = rx_lts_b_f(:,:,ibs) ./ repmat(lts_f',1,N_LTS_SYM);
    H_b(:,:,ibs) = mean(H0_b(:,:,ibs),2);
    idx_0 = find(lts_f == 0);
    H_b(idx_0,:,ibs) = 0;
end
%}

rx_lts_b1 = [rx_lts_mat(rx_lts_idx1,1)  rx_lts_mat(rx_lts_idx2,1)];
rx_lts_b2 = [rx_lts_mat(rx_lts_idx1,2)  rx_lts_mat(rx_lts_idx2,2)];

% Received LTSs for each branch.  
rx_lts_b1_f = fft(rx_lts_b1);
rx_lts_b2_f = fft(rx_lts_b2);

% Channel Estimates of two branches separately:  
H0_b1 = rx_lts_b1_f ./ repmat(lts_f',1,N_LTS_SYM);
H0_b2 = rx_lts_b2_f ./ repmat(lts_f',1,N_LTS_SYM);
H_b1 = mean(H0_b1,2); 
H_b2 = mean(H0_b2,2);
idx_0 = find(lts_f == 0);
H_b1(idx_0,:) = 0;
H_b2(idx_0,:) = 0;

% Channel Estimate of multiple branches:
H_0_t = zeros(N_SC, N_LTS_SYM, N_BS_NODE);
% Take N_SC samples from each rx_lts (we have sent two LTS)
rx_lts_nsc = [rx_lts_mat(rx_lts_idx1,:); rx_lts_mat(rx_lts_idx2,:)];
for ibs = 1:N_BS_NODE
    H_0_t(:,:,ibs) = reshape(rx_lts_nsc(:,ibs),[],N_LTS_SYM);
end
H_0_f = fft(H_0_t, N_SC, 1);
H_0 =  H_0_f./ repmat(lts_f.',1,N_LTS_SYM,N_BS_NODE);

rx_H_est_2d = squeeze(mean(H_0,2));
rx_H_est_2d(idx_0,:) = 0;


%% Rx payload processing

payload_mat = reshape(payload_rx, (N_SC+CP_LEN), N_OFDM_SYM, N_BS_NODE);

% Remove the cyclic prefix, keeping FFT_OFFSET samples of CP (on average)
 payload_mat_noCP = payload_mat(CP_LEN-FFT_OFFSET+(1:N_SC), :,:);

% Take the FFT
syms_f_mat_mrc = fft(payload_mat_noCP, N_SC, 1);
syms_f_mat_1 = syms_f_mat_mrc(:,:,1);
syms_f_mat_2 = syms_f_mat_mrc(:,:,2);

% Equalize MRC
rx_H_est = reshape(rx_H_est_2d,N_SC,1,N_BS_NODE);       % Expand to a 3rd dimension to agree with the dimensions od syms_f_mat
H_pow = sum(abs(conj(rx_H_est_2d).*rx_H_est_2d),2);
H_pow = repmat(H_pow,1,N_OFDM_SYM);

% Do yourselves: MRC equalization:
syms_eq_mat_mrc =  sum( (repmat(conj(rx_H_est), 1, N_OFDM_SYM,1).* syms_f_mat_mrc), 3)./H_pow; % MRC equalization: combine The two branches and equalize. 

%Equalize each branch separately
syms_eq_mat_1 = syms_f_mat_1 ./ repmat(H_b1, 1, N_OFDM_SYM);
syms_eq_mat_2 = syms_f_mat_2 ./ repmat(H_b2, 1, N_OFDM_SYM);


if DO_APPLY_PHASE_ERR_CORRECTION
    % Extract the pilots and calculate per-symbol phase error
    pilots_f_mat_mrc = syms_eq_mat_mrc(SC_IND_PILOTS, :,:);
    pilots_f_mat_comp_mrc = pilots_f_mat_mrc.*pilots_mat;
    pilot_phase_err_mrc = angle(mean(pilots_f_mat_comp_mrc));
    pilots_f_mat_1 = syms_eq_mat_1(SC_IND_PILOTS, :,:);
    pilots_f_mat_comp_1 = pilots_f_mat_1.*pilots_mat;
    pilot_phase_err_1 = angle(mean(pilots_f_mat_comp_1));  
    pilots_f_mat_2 = syms_eq_mat_2(SC_IND_PILOTS, :,:);
    pilots_f_mat_comp_2 = pilots_f_mat_2.*pilots_mat;
    pilot_phase_err_2 = angle(mean(pilots_f_mat_comp_2));
    
else
	% Define an empty phase correction vector (used by plotting code below)
    pilot_phase_err_mrc = zeros(1, N_OFDM_SYM);
    pilot_phase_err_1 = zeros(1, N_OFDM_SYM);
    pilot_phase_err_2 = zeros(1, N_OFDM_SYM);
    
end
pilot_phase_err_corr_mrc = repmat(pilot_phase_err_mrc, N_SC, 1);
pilot_phase_corr_mrc = exp(-1i*(pilot_phase_err_corr_mrc));
pilot_phase_err_corr_1 = repmat(pilot_phase_err_1, N_SC, 1);
pilot_phase_corr_1 = exp(-1i*(pilot_phase_err_corr_1));
pilot_phase_err_corr_2 = repmat(pilot_phase_err_2, N_SC, 1);
pilot_phase_corr_2 = exp(-1i*(pilot_phase_err_corr_2));


% Apply the pilot phase correction per symbol
syms_eq_pc_mat_mrc = syms_eq_mat_mrc .* pilot_phase_corr_mrc;
payload_syms_mat_mrc = syms_eq_pc_mat_mrc(SC_IND_DATA, :);

syms_eq_pc_mat_1 = syms_eq_mat_1 .* pilot_phase_corr_1;
payload_syms_mat_1 = syms_eq_pc_mat_1(SC_IND_DATA, :);

syms_eq_pc_mat_2 = syms_eq_mat_2 .* pilot_phase_corr_2;
payload_syms_mat_2 = syms_eq_pc_mat_2(SC_IND_DATA, :);

%% Demodulate
rx_syms_mrc = reshape(payload_syms_mat_mrc, 1, N_DATA_SYMS);
rx_syms_1 = reshape(payload_syms_mat_1, 1, N_DATA_SYMS);
rx_syms_2 = reshape(payload_syms_mat_2, 1, N_DATA_SYMS);

rx_data_mrc = demod_sym(rx_syms_mrc, MOD_ORDER);
rx_data_1 = demod_sym(rx_syms_1, MOD_ORDER);
rx_data_2 = demod_sym(rx_syms_2, MOD_ORDER);

bit_errs = length(find(dec2bin(bitxor(tx_data, rx_data_mrc),8) == '1'));
ber_SIM(it, isnr) = bit_errs/(N_DATA_SYMS * log2(MOD_ORDER));
    
if (SIM_MOD) && (it == 1) && (sim_SNR_db(isnr) == snr_plot)
    rx_vec_iris_plot = rx_vec_iris;
    rx_data_mrc_plot = rx_data_mrc;
    rx_data_1_plot = rx_data_1; 
    rx_data_2_plot = rx_data_2;
    lts_corr_plot = lts_corr;

    pilot_phase_err_mrc_plot = pilot_phase_err_mrc;
    payload_syms_mat_mrc_plot = payload_syms_mat_mrc;
    payload_syms_mat_1_plot = payload_syms_mat_1;
    payload_syms_mat_2_plot = payload_syms_mat_2;

    rx_H_est_plot = rx_H_est;
    H0_b1_plot = H0_b1; 
    H_b1_plot = H_b1;
    H0_b2_plot = H0_b2; 
    H_b2_plot = H_b2;
    
end

%% end of loop
    end
    
    if (SIM_MOD)
        if chan_type == "awgn"
            awgn = 1;
        else
            awgn  = 0;
        end
        berr_th(isnr) = berr_perfect(sim_SNR_db(isnr), N_BS_NODE, MOD_ORDER, awgn);
    % Display progress
        fprintf(1,'SNR = %f BER = %12.4e BER_no_err = %12.4e \n', sim_SNR_db(isnr), mean(ber_SIM(:,isnr)),  berr_th(isnr));
    end
    
end


%% Plot results
if SIM_MOD
    rx_vec_iris = rx_vec_iris_plot;
    rx_data_mrc = rx_data_mrc_plot;
    rx_data_1 = rx_data_1_plot; 
    rx_data_2 = rx_data_2_plot;
    lts_corr = lts_corr_plot;

    pilot_phase_err_mrc = pilot_phase_err_mrc_plot;
    payload_syms_mat_mrc = payload_syms_mat_mrc_plot;
    payload_syms_mat_1 = payload_syms_mat_1_plot;
    payload_syms_mat_2 = payload_syms_mat_2_plot;

    rx_H_est = rx_H_est_plot;
    H0_b1 = H0_b1_plot; 
    H_b1 = H_b1_plot;
    H0_b2 = H0_b2_plot; 
    H_b2 = H_b2_plot;
end

cf = 0;
fst_clr = [0, 0.4470, 0.7410];
sec_clr = [0.8500, 0.3250, 0.0980];

rx_H_est_plot = repmat(complex(NaN,NaN),1,length(rx_H_est));
rx_H_est_plot(SC_IND_DATA) = rx_H_est(SC_IND_DATA);
rx_H_est_plot(SC_IND_PILOTS) = rx_H_est(SC_IND_PILOTS);

evm_mat_mrc = abs(payload_syms_mat_mrc - tx_syms_mat).^2;
aevms_mrc = mean(evm_mat_mrc(:));
snr_mrc = 10*log10(1./aevms_mrc);

evm_mat_1 = abs(payload_syms_mat_1 - tx_syms_mat).^2;
aevms_1 = mean(evm_mat_1(:));
snr_1 = 10*log10(1./aevms_1);

evm_mat_2 = abs(payload_syms_mat_2 - tx_syms_mat).^2;
aevms_2 = mean(evm_mat_2(:));
snr_2 = 10*log10(1./aevms_2);

sym_errs = sum(tx_data ~= rx_data_mrc);
bit_errs = length(find(dec2bin(bitxor(tx_data, rx_data_mrc),8) == '1'));
rx_evm   = sqrt(sum((real(rx_syms_mrc) - real(tx_syms)).^2 + (imag(rx_syms_mrc) - imag(tx_syms)).^2)/(length(SC_IND_DATA) * N_OFDM_SYM));
sc_data_idx = [(2:27)'; (39:64)' ];
h_pow_mrc = TX_SCALE*sum(H_pow(sc_data_idx,1))/52;

% SNR estimation based on the LTS signals
n_var_1 = sum( sum( abs(H0_b1(sc_data_idx,:) - repmat(H_b1(sc_data_idx), 1,2) ).^2,2 ))/(52*2);
n_var_2 = sum( sum( abs(H0_b2(sc_data_idx,:) - repmat(H_b2(sc_data_idx), 1,2) ).^2,2 ))/(52*2);
h_pow_1 =  TX_SCALE*H_b1(sc_data_idx)'*H_b1(sc_data_idx)/(52);
h_pow_2 =  TX_SCALE*H_b2(sc_data_idx)'*H_b2(sc_data_idx)/(52);
n_var_mrc = (n_var_1 + n_var_2)/2; 

snr_mrc_hat = 10*log10(h_pow_mrc/n_var_mrc);

if(valid_it)
    evm_snr_sw_it(valid_iteration) = snr_mrc;
    ber_sw_it(valid_iteration) = bit_errs/(N_DATA_SYMS * log2(MOD_ORDER));
    pilot_snr_sw_it(valid_iteration) = snr_mrc_hat;
    valid_iteration = valid_iteration +1;
end

    fprintf('Antennas: %d\nCFO sweep: %d\nValid iteration: %d\nIterations: %d\n', N_antennas(antenna_sw), cfo_sw, valid_iteration-1, iteration);
    end
    evm_snr_sw(2*cfo_sw+1) = mean(evm_snr_sw_it);
    pilot_snr_sw(2*cfo_sw+1) = mean(pilot_snr_sw_it);
    ber_sw(2*cfo_sw+1) = mean(ber_sw_it);
end

evm_snr_vec(:,:,antenna_sw) = evm_snr_sw;
pilot_snr_vec(:,:,antenna_sw) = pilot_snr_sw;
ber_vec(:,:,antenna_sw) = ber_sw;

end

cfo_vals = 0:0.5:MAX_CFO_PPM;
figure
for i = 1:length(N_antennas)
    plot(cfo_vals, evm_snr_vec(:,:,i), '-*');
    hold on
end
grid on
%legend('N = 4', 'N = 8', 'N = 16', 'N = 24', 'N = 32');
%legend('N = 8', 'N = 16');
legend('N = 8', 'N = 16', 'N = 24');
xlabel('Max CFO (PPM)');
ylabel('EVM-based SNR (dB)');
title('Rx MRC: EVM-based SNR vs CFO for different number of BS antennas using QPSK modulation');

figure
for i = 1:length(N_antennas)
    plot(cfo_vals, pilot_snr_vec(:,:,i), '-x');
    hold on
end
grid on
%legend('N = 4', 'N = 8', 'N = 16', 'N = 24', 'N = 32');
%legend('N = 8', 'N = 16');
legend('N = 8', 'N = 16', 'N = 24');
xlabel('Max CFO (PPM)');
ylabel('Pilot SNR (dB)');
title('Rx MRC: Pilot SNR vs CFO for different number of BS antennas using QPSK modulation');

figure
for i = 1:length(N_antennas)
    plot(cfo_vals, ber_vec(:,:,i), '-o');
    hold on
end
grid on
%legend('N = 4', 'N = 8', 'N = 16', 'N = 24', 'N = 32');
%legend('N = 8', 'N = 16');
legend('N = 8', 'N = 16', 'N = 24');
xlabel('Max CFO (PPM)');
ylabel('Bit Error Rate');
title('Rx MRC: BER vs CFO for different number of BS antennas using QPSK modulation');



if PLOT
% Tx signal
cf = cf + 1;
figure(cf);clf;

subplot(2,1,1);
plot(real(tx_vec_iris));
axis([0 length(tx_vec_iris) -TX_SCALE TX_SCALE])
grid on;
title('Tx Waveform (I)');

subplot(2,1,2);
plot(imag(tx_vec_iris), 'color', sec_clr);
axis([0 length(tx_vec_iris) -TX_SCALE TX_SCALE])
grid on;
title('Tx Waveform (Q)');

if(WRITE_PNG_FILES)
    print(gcf,sprintf('wl_ofdm_plots_%s_txIQ', example_mode_string), '-dpng', '-r96', '-painters')
end

% Rx signal (only two branches)
cf = cf + 1;
figure(cf);
for sp = 1:N_BS_NODE
    subplot(N_BS_NODE,2,2*(sp -1) + 1 );
    plot(real(rx_vec_iris(:,sp)));
    axis([0 length(rx_vec_iris(:,sp)) -TX_SCALE TX_SCALE])
    grid on;
    %title(sprintf('BS antenna %d Rx Waveform (I)', sp));

    subplot(N_BS_NODE,2,2*sp);
    plot(imag(rx_vec_iris(:,sp)), 'color' , sec_clr);
    axis([0 length(rx_vec_iris(:,sp)) -TX_SCALE TX_SCALE]);
    grid on;
    %title(sprintf('BS antenna %d Rx Waveform (Q)', sp));
end 

if(WRITE_PNG_FILES)
    print(gcf,sprintf('wl_ofdm_plots_%s_rxIQ', example_mode_string), '-dpng', '-r96', '-painters')
end

% Rx LTS correlation (Both branches)
cf = cf + 1;
figure(cf); clf;
lts_to_plot = lts_corr;
plot(lts_to_plot, '.-b', 'LineWidth', 1);
hold on;
grid on;
title('LTS Correlation');
xlabel('Sample Index')
myAxis = axis();
axis([1, 1000, myAxis(3), myAxis(4)])

if(WRITE_PNG_FILES)
    print(gcf,sprintf('wl_ofdm_plots_%s_ltsCorr', example_mode_string), '-dpng', '-r96', '-painters')
end

% Channel Estimates (MRC)
cf = cf + 1;
figure(cf); clf;

x = (20/N_SC) * (-(N_SC/2):(N_SC/2 - 1));

bar(x, fftshift(abs(rx_H_est_plot)),1,'LineWidth', 1);
axis([min(x) max(x) 0 1.1*max(abs(rx_H_est_plot))])
grid on;
title('SIMO Channel Estimates (Magnitude)')
xlabel('Baseband Frequency (MHz)')

if(WRITE_PNG_FILES)
    print(gcf,sprintf('wl_ofdm_plots_%s_chanEst', example_mode_string), '-dpng', '-r96', '-painters')
end

% Symbol constellation
cf = cf + 1;
figure(cf); clf;

plot(payload_syms_mat_mrc(:),'o','MarkerSize',2, 'color', sec_clr);
axis square; axis(1.5*[-1 1 -1 1]);
xlabel('Inphase')
ylabel('Quadrature')
grid on;
hold on;

plot(tx_syms_mat(:),'*', 'MarkerSize',16, 'LineWidth',2, 'color', fst_clr);
title('Tx and Rx Constellations (MRC)')
legend('Rx','Tx','Location','EastOutside');

cf = cf + 1;
figure(cf); clf;

plot(payload_syms_mat_1(:),'o','MarkerSize',2, 'color', sec_clr);
axis square; axis(1.5*[-1 1 -1 1]);
xlabel('Inphase')
ylabel('Quadrature')
grid on;
hold on;

plot(tx_syms_mat(:),'*', 'MarkerSize',16, 'LineWidth',2, 'color', fst_clr);
title('Tx and Rx Constellations (branch 1)')
legend('Rx','Tx','Location','EastOutside');

cf = cf + 1;
figure(cf); clf;

plot(payload_syms_mat_2(:),'o','MarkerSize',2, 'color', sec_clr);
axis square; axis(1.5*[-1 1 -1 1]);
xlabel('Inphase')
ylabel('Quadrature')
grid on;
hold on;

plot(tx_syms_mat(:),'*', 'MarkerSize',16, 'LineWidth',2, 'color', fst_clr);
title('Tx and Rx Constellations (branch 2)')
legend('Rx','Tx','Location','EastOutside');

if(WRITE_PNG_FILES)
    print(gcf,sprintf('wl_ofdm_plots_%s_constellations', example_mode_string), '-dpng', '-r96', '-painters')
end


%EVM & SNR
cf = cf + 1;
figure(cf); clf;

subplot(2,1,1)
plot(100*evm_mat_mrc(:),'o','MarkerSize',1)
axis tight
hold on
plot([1 length(evm_mat_mrc(:))], 100*[aevms_mrc, aevms_mrc],'color', sec_clr, 'LineWidth',4)
myAxis = axis;
h = text(round(.05*length(evm_mat_mrc(:))), 100*aevms_mrc+ .1*(myAxis(4)-myAxis(3)), sprintf('Effective SNR: %.1f dB', snr_mrc));
set(h,'Color',[1 0 0])
set(h,'FontWeight','bold')
set(h,'FontSize',10)
set(h,'EdgeColor',[1 0 0])
set(h,'BackgroundColor',[1 1 1])
hold off
xlabel('Data Symbol Index')
ylabel('EVM (%)');
legend('Per-Symbol EVM','Average EVM','Location','NorthWest');
title('EVM vs. Data Symbol Index (MRC)')
grid on

subplot(2,1,2)
imagesc(1:N_OFDM_SYM, (SC_IND_DATA - N_SC/2), 100*fftshift(evm_mat_mrc,1))

grid on
xlabel('OFDM Symbol Index')
ylabel('Subcarrier Index')
title('EVM vs. (Subcarrier & OFDM Symbol)')
h = colorbar;
set(get(h,'title'),'string','EVM (%)');
myAxis = caxis();
if (myAxis(2)-myAxis(1)) < 5
    caxis([myAxis(1), myAxis(1)+5])
end


cf = cf + 1;
figure(cf); clf;

subplot(2,1,1)
plot(100*evm_mat_1(:),'o','MarkerSize',1)
axis tight
hold on
plot([1 length(evm_mat_1(:))], 100*[aevms_1, aevms_1],'color', sec_clr,'LineWidth',4)
myAxis = axis;
h = text(round(.05*length(evm_mat_1(:))), 100*aevms_1 + .1*(myAxis(4)-myAxis(3)), sprintf('Effective SNR: %.1f dB', snr_1));
set(h,'Color',[1 0 0])
set(h,'FontWeight','bold')
set(h,'FontSize',10)
set(h,'EdgeColor',[1 0 0])
set(h,'BackgroundColor',[1 1 1])
hold off
xlabel('Data Symbol Index')
ylabel('EVM (%)');
legend('Per-Symbol EVM','Average EVM','Location','NorthWest');
title('EVM vs. Data Symbol Index (branch 1)')
grid on

subplot(2,1,2)
imagesc(1:N_OFDM_SYM, (SC_IND_DATA - N_SC/2), 100*fftshift(evm_mat_mrc,1))

grid on
xlabel('OFDM Symbol Index')
ylabel('Subcarrier Index')
title('EVM vs. (Subcarrier & OFDM Symbol)')
h = colorbar;
set(get(h,'title'),'string','EVM (%)');
myAxis = caxis();
if (myAxis(2)-myAxis(1)) < 5
    caxis([myAxis(1), myAxis(1)+5])
end



cf = cf + 1;
figure(cf); clf;

subplot(2,1,1)
plot(100*evm_mat_2(:),'o','MarkerSize',1)
axis tight
hold on
plot([1 length(evm_mat_2(:))], 100*[aevms_2, aevms_2],'color', sec_clr,'LineWidth',4)
myAxis = axis;
h = text(round(.05*length(evm_mat_2(:))), 100*aevms_2+ .1*(myAxis(4)-myAxis(3)), sprintf('Effective SNR: %.1f dB', snr_2));
set(h,'Color',[1 0 0])
set(h,'FontWeight','bold')
set(h,'FontSize',10)
set(h,'EdgeColor',[1 0 0])
set(h,'BackgroundColor',[1 1 1])
hold off
xlabel('Data Symbol Index')
ylabel('EVM (%)');
legend('Per-Symbol EVM','Average EVM','Location','NorthWest');
title('EVM vs. Data Symbol Index (branch 2)')
grid on

subplot(2,1,2)
imagesc(1:N_OFDM_SYM, (SC_IND_DATA - N_SC/2), 100*fftshift(evm_mat_mrc,1))

grid on
xlabel('OFDM Symbol Index')
ylabel('Subcarrier Index')
title('EVM vs. (Subcarrier & OFDM Symbol)')
h = colorbar;
set(get(h,'title'),'string','EVM (%)');
myAxis = caxis();
if (myAxis(2)-myAxis(1)) < 5
    caxis([myAxis(1), myAxis(1)+5])
end




if(WRITE_PNG_FILES)
    print(gcf,sprintf('wl_ofdm_plots_%s_evm', example_mode_string), '-dpng', '-r96', '-painters')
end

% BER SIM MOD
if SIM_MOD
    sym_errs = sum(tx_data ~= rx_data_mrc);
bit_errs = length(find(dec2bin(bitxor(tx_data, rx_data_mrc),8) == '1'));
rx_evm   = sqrt(sum((real(rx_syms_mrc) - real(tx_syms)).^2 + (imag(rx_syms_mrc) - imag(tx_syms)).^2)/(length(SC_IND_DATA) * N_OFDM_SYM));
    cf = cf+1;
    figure(cf);
    ber_avg = mean(ber_SIM)';
    semilogy(sim_SNR_db, [ber_avg berr_th], 'o-', 'LineWidth', 2);
    axis([0 sim_SNR_db(end) 1e-3 1]);
    hold on;
    plot(xlim, [1 1]*1e-2, '--r', 'linewidth', 2);
    legend('Simulation', 'No Eq. Error', '1% BER');
    grid on;
    set(gca,'FontSize',16);
    xlabel('SNR (dB)');
    ylabel('BER');
    hold off;
    title('Bit Error rate vs SNR');
end
end

% Calculate Rx stats

fprintf('\n MRC Results:\n');
fprintf('Num Bytes:   %d\n', N_DATA_SYMS * log2(MOD_ORDER) / 8);
fprintf('Sym Errors:  %d (of %d total symbols)\n', sym_errs, N_DATA_SYMS);
fprintf('Bit Errors:  %d (of %d total bits)\n', bit_errs, N_DATA_SYMS * log2(MOD_ORDER));

 
fprintf('\n\tEVM-based SNRs:\n');
fprintf('Branch 1 SNR:%3.2f \tBranch 2 SNR:%3.2f\t MRC SNR:%3.2f\n',...
    snr_1, snr_2, snr_mrc);

snr_1_hat = 10*log10(h_pow_1/n_var_1);
snr_2_hat = 10*log10(h_pow_2/n_var_2);
snr_1_plus_snr = 10*log10(h_pow_1/n_var_1 +  h_pow_2/n_var_2);
fprintf('\tPilot SNR Estimates:\n');
fprintf('Branch 1 SNR:%3.2f \tBranch 2 SNR:%3.2f\t MRC SNR:%3.2f\n',...
    snr_1_hat, snr_2_hat, snr_mrc_hat);
