# React hooks cleanup vs unmount

A common confusion: people think `useEffect` cleanup only runs at unmount.
In fact it runs *before each new effect invocation* — including between
re-renders when dependencies change.

This means cleanup gets called many more times than people expect, and any
expensive teardown logic should account for that.
