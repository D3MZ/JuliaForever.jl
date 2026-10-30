export async function resolve(specifier, context, nextResolve) {
    if (context.parentURL?.includes('/packages/ai/src/providers/') && specifier.startsWith('./data/') && specifier.endsWith('.json')) {
        return { url: 'data:application/json,%7B%7D', shortCircuit: true };
    }
    return nextResolve(specifier, context);
}
