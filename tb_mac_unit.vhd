library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

-- Testbench da mac_unit.
-- Cobre: reset, clear sincrono, MAC simples (a*b), MAC iterado (somatorio),
-- numeros negativos e clear no meio de uma sequencia.
entity tb_mac_unit is
end tb_mac_unit;

architecture sim of tb_mac_unit is

    component mac_unit
        Port (
            clk     : in  std_logic;
            reset   : in  std_logic;
            clear   : in  std_logic;
            en      : in  std_logic;
            a       : in  std_logic_vector(15 downto 0);
            b       : in  std_logic_vector(15 downto 0);
            acc_out : out std_logic_vector(31 downto 0)
        );
    end component;

    constant CLK_PERIOD : time := 10 ns;

    signal clk     : std_logic := '0';
    signal reset   : std_logic := '1';
    signal clear   : std_logic := '0';
    signal en      : std_logic := '0';
    signal a       : std_logic_vector(15 downto 0) := (others => '0');
    signal b       : std_logic_vector(15 downto 0) := (others => '0');
    signal acc_out : std_logic_vector(31 downto 0);

    signal sim_done : boolean := false;
    signal err_cnt  : integer := 0;

    -- Tipos auxiliares para vetores de teste
    type vec16_t is array (natural range <>) of integer;

    -- Converte inteiro para slv 16 bits signed
    function to_slv16(i : integer) return std_logic_vector is
    begin
        return std_logic_vector(to_signed(i, 16));
    end function;

    -- Verifica acc_out contra valor esperado e reporta falhas
    procedure check(
        constant tag      : in string;
        constant expected : in integer;
        signal   acc      : in std_logic_vector(31 downto 0);
        signal   errs     : inout integer
    ) is
        variable got : integer;
    begin
        got := to_integer(signed(acc));
        if got = expected then
            report tag & " OK (acc = " & integer'image(got) & ")"
                severity note;
        else
            report tag & " FALHOU: esperado " & integer'image(expected)
                & ", obtido " & integer'image(got)
                severity error;
            errs <= errs + 1;
        end if;
    end procedure;

begin

    -- Clock
    clk_proc : process
    begin
        while not sim_done loop
            clk <= '0';
            wait for CLK_PERIOD / 2;
            clk <= '1';
            wait for CLK_PERIOD / 2;
        end loop;
        wait;
    end process;

    -- DUT
    DUT : mac_unit
        port map (
            clk     => clk,
            reset   => reset,
            clear   => clear,
            en      => en,
            a       => a,
            b       => b,
            acc_out => acc_out
        );

    -- Estimulos
    stim : process
        -- Vetores de teste para o somatorio
        constant av : vec16_t := ( 2,  3,  -4,   5,  10);
        constant bv : vec16_t := ( 7, -1,   6,  -2,  -3);
        -- esperado = 2*7 + 3*(-1) + (-4)*6 + 5*(-2) + 10*(-3) = 14 -3 -24 -10 -30 = -53
        variable expected_sum : integer := 0;
    begin
        ---------------------------------------------------------------
        -- T1: reset assincrono zera o acumulador
        ---------------------------------------------------------------
        reset <= '1';
        clear <= '0';
        en    <= '0';
        a     <= (others => '0');
        b     <= (others => '0');
        wait for 2 * CLK_PERIOD;
        reset <= '0';
        wait until rising_edge(clk);
        check("T1 reset", 0, acc_out, err_cnt);

        ---------------------------------------------------------------
        -- T2: uma unica multiplicacao acumulada (a partir de zero)
        --     acc <- 0 + 3*4 = 12
        ---------------------------------------------------------------
        a  <= to_slv16(3);
        b  <= to_slv16(4);
        en <= '1';
        wait until rising_edge(clk);
        en <= '0';
        wait until rising_edge(clk);
        check("T2 mac simples (3*4)", 12, acc_out, err_cnt);

        ---------------------------------------------------------------
        -- T3: acumular novo produto sem limpar
        --     acc <- 12 + (-5)*6 = -18
        ---------------------------------------------------------------
        a  <= to_slv16(-5);
        b  <= to_slv16(6);
        en <= '1';
        wait until rising_edge(clk);
        en <= '0';
        wait until rising_edge(clk);
        check("T3 mac acumulado com negativo", -18, acc_out, err_cnt);

        ---------------------------------------------------------------
        -- T4: clear sincrono zera o acumulador
        ---------------------------------------------------------------
        clear <= '1';
        wait until rising_edge(clk);
        clear <= '0';
        wait until rising_edge(clk);
        check("T4 clear", 0, acc_out, err_cnt);

        ---------------------------------------------------------------
        -- T5: clear tem prioridade sobre en no mesmo ciclo
        --     coloca um valor, depois aciona clear+en juntos -> deve zerar
        ---------------------------------------------------------------
        a  <= to_slv16(10);
        b  <= to_slv16(10);
        en <= '1';
        wait until rising_edge(clk);
        check("T5a pre-clear (10*10)", 100, acc_out, err_cnt);

        clear <= '1';
        a     <= to_slv16(7);
        b     <= to_slv16(7);
        en    <= '1';
        wait until rising_edge(clk);
        clear <= '0';
        en    <= '0';
        wait until rising_edge(clk);
        check("T5b clear sobrepoe en", 0, acc_out, err_cnt);

        ---------------------------------------------------------------
        -- T6: en=0 mantem o valor (sem alteracao)
        ---------------------------------------------------------------
        a  <= to_slv16(9);
        b  <= to_slv16(9);
        en <= '1';
        wait until rising_edge(clk);
        check("T6a pre-hold (9*9)", 81, acc_out, err_cnt);

        en <= '0';
        a  <= to_slv16(50);  -- mudancas em a/b nao devem afetar acc
        b  <= to_slv16(50);
        wait until rising_edge(clk);
        wait until rising_edge(clk);
        check("T6b hold com en=0", 81, acc_out, err_cnt);

        ---------------------------------------------------------------
        -- T7: somatorio iterado (5 produtos), checando o resultado final
        --     equivale a uma sequencia tipica COMPUTE do controller
        ---------------------------------------------------------------
        clear <= '1';
        en    <= '0';
        wait until rising_edge(clk);
        clear <= '0';

        expected_sum := 0;
        for i in av'range loop
            a  <= to_slv16(av(i));
            b  <= to_slv16(bv(i));
            en <= '1';
            expected_sum := expected_sum + av(i) * bv(i);
            wait until rising_edge(clk);
        end loop;
        en <= '0';
        wait until rising_edge(clk);
        check("T7 somatorio iterado (5 termos)", expected_sum, acc_out, err_cnt);

        ---------------------------------------------------------------
        -- T8: produto de valores grandes excede 16 bits, mas cabe em 32
        --     1000 * 1000 = 1_000_000
        ---------------------------------------------------------------
        clear <= '1';
        wait until rising_edge(clk);
        clear <= '0';

        a  <= to_slv16(1000);
        b  <= to_slv16(1000);
        en <= '1';
        wait until rising_edge(clk);
        en <= '0';
        wait until rising_edge(clk);
        check("T8 produto de 32 bits", 1_000_000, acc_out, err_cnt);

        ---------------------------------------------------------------
        -- T9: extremos signed -- min * min = (-32768) * (-32768) = 2^30
        ---------------------------------------------------------------
        clear <= '1';
        wait until rising_edge(clk);
        clear <= '0';

        a  <= to_slv16(-32768);
        b  <= to_slv16(-32768);
        en <= '1';
        wait until rising_edge(clk);
        en <= '0';
        wait until rising_edge(clk);
        check("T9 (-32768)*(-32768)", 1073741824, acc_out, err_cnt);

        ---------------------------------------------------------------
        -- Fim
        ---------------------------------------------------------------
        if err_cnt = 0 then
            report "=== TODOS OS TESTES PASSARAM ===" severity note;
        else
            report "=== FALHAS: " & integer'image(err_cnt) & " ===" severity failure;
        end if;

        sim_done <= true;
        wait;
    end process;

end sim;
