%% SYNC vs Stimulator Output
% CH1 = Arduino SYNC pin
% CH2 = Stimulator output

clear;
clc;
close all;



%% Data folder
dataFolder = pwd;

%% Load data
ch1File = fullfile(dataFolder, 'CH1.CSV');
ch2File = fullfile(dataFolder, 'CH2.CSV');

ch1 = readmatrix(ch1File);
ch2 = readmatrix(ch2File);
%% Remove rows containing NaN values
% Useful if the oscilloscope CSV contains header information
ch1 = ch1(all(~isnan(ch1(:,1:2)), 2), :);
ch2 = ch2(all(~isnan(ch2(:,1:2)), 2), :);

%% Extract time and voltage
% Assumes:
% Column 1 = time
% Column 2 = voltage

t1 = ch1(:,1);
v1 = ch1(:,2);

t2 = ch2(:,1);
v2 = ch2(:,2);

%% Plot individual channels
figure;

subplot(2,1,1);
plot(t1, v1, 'LineWidth', 1.2);
grid on;
xlabel('Time (s)');
ylabel('Voltage (V)');
title('Channel 1: Arduino SYNC');

subplot(2,1,2);
plot(t2, v2, 'LineWidth', 1.2);
grid on;
xlabel('Time (s)');
ylabel('Voltage (V)');
title('Channel 2: Stimulator Output');

%% Plot both together for comparison
figure;

yyaxis left
plot(t1, v1, 'LineWidth', 1.2);
ylabel('SYNC Voltage (V)');

yyaxis right
plot(t2, v2, 'LineWidth', 1.2);
ylabel('Stimulator Output (V)');

xlabel('Time (s)');
title('SYNC vs Stimulator Output');
grid on;

legend('SYNC', 'Stimulator Output');