.PHONY: test

test:
	nvim --headless -u scripts/minimal_init.lua -c "lua MiniTest.run()"
