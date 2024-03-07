// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

import * as http from 'http';
import { CancelledResponse, ErrorResponse, JsonServerResponse, SuccessResponseBase, UndefinedResponse, startJsonServer } from './jsonServer';
import { IActionContext, IAzureQuickPickItem, IAzureQuickPickOptions, UserCancelledError, callWithTelemetryAndErrorHandling, isUserCancelledError } from '@microsoft/vscode-azext-utils';
import { MessageItem } from 'vscode';

type PromptServerSuccessResponse = SuccessResponseBase & {
    value: boolean | string | string[] | number | number[];
};

type PromptServerResponse = PromptServerSuccessResponse | ErrorResponse | CancelledResponse | undefined;

const AllPromptTypes = ['string', 'password', 'select', 'multiSelect', 'confirm', 'directory'] as const;
type PromptTypeTuple = typeof AllPromptTypes;
type PromptType = PromptTypeTuple[number];

type PromptServerRequest = {
    type: PromptType;
    options: {
        message: string;
        help: string | undefined;
        options: SelectOption[] | undefined;
        defaultValue: string | undefined;
    }
};

type SelectOption = {
    label: string;
    description: string | undefined;
};

function isValidSelectOption(obj: unknown): obj is SelectOption {
    if (typeof obj !== 'object' || obj === null) {
        return false;
    }

    const maybeSelectOption = obj as SelectOption;

    if (typeof maybeSelectOption.label !== 'string') {
        return false;
    }

    if (!!maybeSelectOption.description && typeof maybeSelectOption.description !== 'string') {
        return false;
    }

    return true;
}

function isValidPromptServerRequest(obj: unknown): obj is PromptServerRequest {
    if (typeof obj !== 'object' || obj === null) {
        return false;
    }

    const maybePromptServerRequest = obj as PromptServerRequest;

    if (typeof maybePromptServerRequest.type !== 'string' || !AllPromptTypes.includes(maybePromptServerRequest.type)) {
        return false;
    }

    if (typeof maybePromptServerRequest.options !== 'object' || maybePromptServerRequest.options === null) {
        return false;
    }

    if (typeof maybePromptServerRequest.options.message !== 'string') {
        return false;
    }

    if (!!maybePromptServerRequest.options.help && typeof maybePromptServerRequest.options.help !== 'string') {
        return false;
    }

    if ((maybePromptServerRequest.type === 'select' || maybePromptServerRequest.type === 'multiSelect' || maybePromptServerRequest.type === 'confirm') && !!maybePromptServerRequest.options.options) {
        return false;
    }

    if ((!Array.isArray(maybePromptServerRequest.options.options) || !maybePromptServerRequest.options.options.every(isValidSelectOption))) {
        return false;
    }

    if (!!maybePromptServerRequest.options.defaultValue && typeof maybePromptServerRequest.options.defaultValue !== 'string') {
        return false;
    }

    return true;
}

/**
 * `startPromptServer` creates a locally running server that will respond to Azure Dev CLI prompt requests and
 * starts listening for requests.  Requests must be authenticated with a key that is returned from this function.
 **/
export function startPromptServer(): Promise<{ server: http.Server, endpoint: string, key: string }> {
    return startJsonServer({
        // eslint-disable-next-line @typescript-eslint/naming-convention
        '/prompt?api-version=2024-02-14-preview': async (reqBody: unknown): Promise<JsonServerResponse<PromptServerResponse>> => {
            return (await callWithTelemetryAndErrorHandling('promptServer.prompt', async (actionContext: IActionContext) => {
                if (!isValidPromptServerRequest(reqBody)) {
                    return { statusCode: 400 } satisfies JsonServerResponse<UndefinedResponse>;
                }

                try {
                    switch (reqBody.type) {
                        case 'string':
                        case 'password': {
                            const value = await promptString(actionContext, reqBody.type === 'password', reqBody.options.message, reqBody.options.defaultValue, reqBody.options.help);
                            return {
                                statusCode: 200,
                                result: {
                                    status: 'success',
                                    value: value,
                                },
                            } satisfies JsonServerResponse<PromptServerSuccessResponse>;
                        }
                        case 'select':
                        case 'multiSelect': {
                            const value = await promptSelect(actionContext, reqBody.type === 'multiSelect', reqBody.options.message, reqBody.options.options!, reqBody.options.defaultValue, reqBody.options.help);
                            return {
                                statusCode: 200,
                                result: {
                                    status: 'success',
                                    value: value,
                                },
                            } satisfies JsonServerResponse<PromptServerSuccessResponse>;
                        }
                        case 'confirm': {
                            const value = await promptConfirmation(actionContext, reqBody.options.message, reqBody.options.options!, reqBody.options.help);
                            return {
                                statusCode: 200,
                                result: {
                                    status: 'success',
                                    value: value,
                                },
                            } satisfies JsonServerResponse<PromptServerSuccessResponse>;
                        }
                        case 'directory': {
                            const value = await promptDirectory(actionContext, reqBody.options.message, reqBody.options.help);
                            return {
                                statusCode: 200,
                                result: {
                                    status: 'success',
                                    value: value,
                                },
                            } satisfies JsonServerResponse<PromptServerSuccessResponse>;
                        }
                    }
                } catch (e: unknown) {
                    if (isUserCancelledError(e)) {
                        return { statusCode: 200, result: { status: 'cancelled' } } satisfies JsonServerResponse<CancelledResponse>;
                    }

                    throw e;
                }
            }))!;
        }
    });
}

async function promptString(context: IActionContext, isPassword: boolean, message: string, defaultValue?: string, help?: string): Promise<string> {
    return await context.ui.showInputBox({
        prompt: message,
        placeHolder: help,
        password: isPassword,
        ignoreFocusOut: true,
        value: defaultValue,
    });
}

async function promptSelect(context: IActionContext, isMulti: boolean, message: string, options: SelectOption[], defaultValue?: string, help?: string): Promise<number | number[]> {
    const items: IAzureQuickPickItem<number>[] = options.map((option, index) => { return { label: option.label, description: option.description, data: index }; });

    const quickPickOptions: IAzureQuickPickOptions = {
        placeHolder: help,
        title: message,
        ignoreFocusOut: true,
        isPickSelected: p => p.label === defaultValue,
    };

    // This is done this way, instead of just `{ canPickMany: isMulti }`, to allow TypeScript to better infer the type of the result object(s) returned
    if (isMulti) {
        const results = await context.ui.showQuickPick(items, { ...quickPickOptions, canPickMany: true });
        return results.map((result) => result.data);
    } else {
        const result = await context.ui.showQuickPick(items, quickPickOptions);
        return result.data;
    }
}

interface IAzureMessageItem<T> extends MessageItem {
    data: T;
}

async function promptConfirmation(context: IActionContext, message: string, options: SelectOption[], help?: string): Promise<number> {
    const buttons: IAzureMessageItem<number>[] = options.map((option, index) => { return { title: option.label, data: index }; });

    const selection = await context.ui.showWarningMessage(
        message,
        { modal: true, detail: help },
        ...buttons,
    );

    return selection.data;
}

async function promptDirectory(context: IActionContext, message: string, help?: string): Promise<string> {
    const selection = await context.ui.showOpenDialog({
        canSelectFiles: false,
        canSelectFolders: true,
        canSelectMany: false,
        title: message,
    });

    if (selection.length === 0) {
        throw new UserCancelledError();
    }

    return selection[0].fsPath;
}