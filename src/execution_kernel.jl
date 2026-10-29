function Execution.submit!(executor::Execution.Executor, pending::Kernel.Pending, attempt::Integer)
    Execution.submit!(executor, pending.id, attempt, pending.effect)
end
