%% CheckScopeCSV.m
% Quick Rigol CSV sanity check
%
% This script DOES NOT load the whole waveform into MATLAB.
% It only:
%   1. reads the header
%   2. counts rows efficiently in chunks
%   3. extracts t0 and tInc if present
%   4. calculates sample rate and capture duration
%   5. estimates how many samples cover your fast OpenXstim transient
%
% Edit only the USER SETTINGS section.

clear;
clc;

%% USER SETTINGS

filename = "enc_6_2.csv";

% Approximate fast analogue rise/fall time seen previously
expectedFastTransition_us = 5.0;

% A useful target for low-order system identification
targetSamplesAcrossTransition = 50;

%% FILE INFORMATION

if ~isfile(filename)
    error("Cannot find file: %s\nCurrent folder: %s", filename, pwd);
end

info = dir(filename);

fprintf("\n============================================================\n");
fprintf("RIGOL CSV CHECK\n");
fprintf("============================================================\n");

fprintf("File: %s\n", fullfile(info.folder,info.name));
fprintf("File size: %.2f MB\n", info.bytes/1e6);

%% READ HEADER ONLY

fid = fopen(filename,'r');

if fid < 0
    error("Could not open file.");
end

header = fgetl(fid);
fclose(fid);

fprintf("\nHeader:\n%s\n", header);

% Extract channel labels from the text before the first comma containing t0.
parts = split(string(header),",");

channelNames = strings(0,1);

for k = 1:numel(parts)
    p = strtrim(parts(k));

    if startsWith(p,"t0") || contains(p,"tInc")
        break;
    end

    if strlength(p) > 0
        channelNames(end+1,1) = p; %#ok<SAGROW>
    end
end

fprintf("\nDetected channel columns: %d\n", numel(channelNames));

for k = 1:numel(channelNames)
    fprintf("  Column %d: %s\n", k, channelNames(k));
end

%% PARSE t0 AND tInc FROM HEADER

t0 = NaN;
tInc = NaN;

tok = regexp(header, ...
    't0\s*=\s*([+-]?\d*\.?\d+(?:[eE][+-]?\d+)?)', ...
    'tokens','once');

if ~isempty(tok)
    t0 = str2double(tok{1});
end

tok = regexp(header, ...
    'tInc\s*=\s*([+-]?\d*\.?\d+(?:[eE][+-]?\d+)?)', ...
    'tokens','once');

if ~isempty(tok)
    tInc = str2double(tok{1});
end

fprintf("\nTiming metadata:\n");
fprintf("  t0   = %.12g s\n", t0);
fprintf("  tInc = %.12g s\n", tInc);

if isfinite(tInc) && tInc > 0
    fs = 1/tInc;
    fprintf("  Fs   = %.6f MSa/s\n", fs/1e6);
else
    fs = NaN;
    warning("Could not extract a valid tInc from the header.");
end

%% COUNT LINES WITHOUT LOADING THE FULL CSV

fprintf("\nCounting rows efficiently...\n");

fid = fopen(filename,'r');

if fid < 0
    error("Could not reopen file.");
end

% Count newline characters in large binary chunks.
chunkSize = 16*1024*1024;  % 16 MB
newlineCount = 0;

while ~feof(fid)
    bytes = fread(fid,chunkSize,'*uint8');
    newlineCount = newlineCount + sum(bytes == 10); % LF
end

fclose(fid);

totalLines = newlineCount;

% Rigol file has one metadata/header line.
dataRows = max(0,totalLines - 1);

fprintf("  Total lines : %d\n", totalLines);
fprintf("  Data rows   : %d\n", dataRows);

%% CAPTURE DURATION

if isfinite(tInc) && dataRows > 1
    captureDuration = (dataRows-1)*tInc;

    fprintf("\nCapture duration:\n");
    fprintf("  %.9f s\n", captureDuration);
    fprintf("  %.6f ms\n", captureDuration*1e3);
else
    captureDuration = NaN;
end

%% FAST-DYNAMICS RESOLUTION CHECK

if isfinite(fs)

    transition_s = expectedFastTransition_us*1e-6;

    samplesAcross = transition_s/tInc;

    fprintf("\nFast-transition resolution:\n");
    fprintf("  Assumed transition time       : %.3f us\n", ...
        expectedFastTransition_us);
    fprintf("  Samples across transition     : %.1f samples\n", ...
        samplesAcross);

    minimumFs = ...
        targetSamplesAcrossTransition/transition_s;

    fprintf("  Target samples per transition : %d\n", ...
        targetSamplesAcrossTransition);
    fprintf("  Fs needed for that target     : %.3f MSa/s\n", ...
        minimumFs/1e6);

    if samplesAcross >= targetSamplesAcrossTransition
        fprintf("  RESULT: Excellent resolution for identification.\n");
    elseif samplesAcross >= 20
        fprintf("  RESULT: Usable resolution for low-order identification.\n");
    else
        fprintf("  RESULT: Too coarse for reliable fast-dynamics fitting.\n");
    end
end

%% MEMORY-DEPTH GUIDANCE

if isfinite(captureDuration)

    fprintf("\nSuggested point counts for the SAME capture duration:\n");

    candidates = [250e3 500e3 1e6 2e6 5e6 10e6];

    fprintf("  Points       Effective Fs      Samples across %.1f us\n", ...
        expectedFastTransition_us);

    for N = candidates

        fsCandidate = N/captureDuration;
        samplesCandidate = ...
            expectedFastTransition_us*1e-6*fsCandidate;

        fprintf("  %8.0f     %9.3f MSa/s        %8.1f\n", ...
            N,fsCandidate/1e6,samplesCandidate);
    end

    recommendedPoints = ...
        ceil(targetSamplesAcrossTransition * ...
        captureDuration / (expectedFastTransition_us*1e-6));

    fprintf("\nMinimum points for ~%d samples across a %.1f us transition\n", ...
        targetSamplesAcrossTransition,expectedFastTransition_us);
    fprintf("over this same capture duration: about %.0f points\n", ...
        recommendedPoints);
end

%% STORAGE ESTIMATE

if dataRows > 0

    bytesPerRowApprox = info.bytes/dataRows;

    fprintf("\nStorage estimate:\n");
    fprintf("  Approx CSV bytes/data row: %.1f bytes\n", ...
        bytesPerRowApprox);

    for N = [500e3 1e6 2e6 10e6]
        fprintf("  %.1f Mpts -> about %.1f MB per CSV\n", ...
            N/1e6,(N*bytesPerRowApprox)/1e6);
    end
end

fprintf("\n============================================================\n");
fprintf("CHECK COMPLETE\n");
fprintf("============================================================\n");
